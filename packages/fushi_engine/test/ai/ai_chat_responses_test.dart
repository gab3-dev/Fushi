import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

AiProviderConfig _planProvider() => AiProviderConfig(
  id: 'plan-provider',
  presetId: kAiChatGptPlanPresetId,
  name: 'ChatGPT plan',
  baseUrl: Uri.parse('https://api.openai.com/v1'),
  chatGptPlanCredentialId: 'oauth-record',
  protocol: AiWireProtocol.openAiResponses,
  model: 'gpt-6-test',
  acceptsImages: true,
);

String _completedSse({
  List<Map<String, Object?>> output = const <Map<String, Object?>>[
    <String, Object?>{
      'type': 'message',
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'output_text', 'text': 'response text'},
      ],
    },
  ],
}) =>
    'event: response.completed\n'
    'data: ${jsonEncode(<String, Object?>{
      'type': 'response.completed',
      'response': <String, Object?>{
        'status': 'completed',
        'output': output,
        'usage': <String, Object?>{
          'input_tokens': 18,
          'output_tokens': 6,
          'input_tokens_details': <String, Object?>{'cached_tokens': 5},
        },
      },
    })}\n\n';

void main() {
  test(
    'plan Responses requests use OAuth, required flags, and normalized usage',
    () async {
      http.Request? sent;
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        planAccessTokenResolver: (String id) async {
          expect(id, 'oauth-record');
          return 'short-lived-access-token';
        },
        client: MockClient((http.Request request) async {
          sent = request;
          return http.Response(
            _completedSse(),
            200,
            headers: const <String, String>{
              'content-type': 'text/event-stream',
            },
          );
        }),
      );
      addTearDown(client.close);

      final AiChatCompletion completion = await client.completeWithUsage(
        provider: _planProvider(),
        messages: const <AiChatMessage>[
          AiChatMessage.system('system instructions'),
          AiChatMessage.user('question'),
        ],
        maxTokens: 32,
      );

      expect(completion.text, 'response text');
      expect(
        completion.usage,
        const AiChatUsage(inputTokens: 13, cacheReadTokens: 5, outputTokens: 6),
      );
      expect(sent!.url, Uri.parse('https://api.openai.com/v1/responses'));
      expect(sent!.headers['authorization'], 'Bearer short-lived-access-token');
      final Map<String, Object?> body =
          jsonDecode(sent!.body) as Map<String, Object?>;
      expect(body['instructions'], 'system instructions');
      expect(body['store'], isFalse);
      expect(body['stream'], isTrue);
      expect(body.containsKey('max_output_tokens'), isFalse);
      expect(body['input'], <Map<String, Object?>>[
        <String, Object?>{'role': 'user', 'content': 'question'},
      ]);
    },
  );

  test('plan Responses maps image input and local function calls', () async {
    http.Request? sent;
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      planAccessTokenResolver: (_) async => 'access-token',
      client: MockClient((http.Request request) async {
        sent = request;
        return http.Response(
          _completedSse(
            output: <Map<String, Object?>>[
              <String, Object?>{
                'type': 'function_call',
                'call_id': 'call-1',
                'name': 'open_item',
                'arguments': '{"key":"42"}',
              },
            ],
          ),
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
        );
      }),
    );
    addTearDown(client.close);

    final AiChatTurn turn = await client.chat(
      provider: _planProvider(),
      messages: <AiChatMessage>[
        const AiChatMessage.user(
          'read this image',
          images: <AiChatImage>[
            AiChatImage(bytes: <int>[1, 2, 3]),
          ],
        ),
        const AiChatMessage.assistantToolCalls('', <AiChatToolCall>[
          AiChatToolCall(
            id: 'old-call',
            name: 'open_item',
            arguments: <String, Object?>{'key': '41'},
          ),
        ]),
        const AiChatMessage.toolResult(
          toolCallId: 'old-call',
          toolName: 'open_item',
          content: 'opened',
        ),
      ],
      tools: const <AiChatToolSpec>[
        AiChatToolSpec(
          name: 'open_item',
          description: 'Open an item',
          parameters: <String, Object?>{'type': 'object'},
        ),
      ],
    );

    expect(turn.toolCalls, hasLength(1));
    expect(turn.toolCalls.single.name, 'open_item');
    expect(turn.toolCalls.single.arguments, <String, Object?>{'key': '42'});
    final Map<String, Object?> body =
        jsonDecode(sent!.body) as Map<String, Object?>;
    final List<Object?> input = body['input']! as List<Object?>;
    expect(input[0], <String, Object?>{
      'role': 'user',
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'input_text', 'text': 'read this image'},
        <String, Object?>{
          'type': 'input_image',
          'image_url': 'data:image/png;base64,AQID',
        },
      ],
    });
    expect(input[1], <String, Object?>{
      'type': 'function_call',
      'call_id': 'old-call',
      'name': 'open_item',
      'arguments': '{"key":"41"}',
    });
    expect(input[2], <String, Object?>{
      'type': 'function_call_output',
      'call_id': 'old-call',
      'output': 'opened',
    });
    expect(body['tools'], <Map<String, Object?>>[
      <String, Object?>{
        'type': 'function',
        'name': 'open_item',
        'description': 'Open an item',
        'parameters': <String, Object?>{'type': 'object'},
      },
    ]);
  });

  test(
    'ChatGPT-plan cloud transcription is rejected without sending audio',
    () async {
      int requests = 0;
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        planAccessTokenResolver: (_) async => 'access-token',
        client: MockClient((http.Request _) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.transcribeAudio(
          provider: _planProvider(),
          audioBytes: <int>[1, 2, 3],
          fileName: 'sample.wav',
          contentType: 'audio/wav',
        ),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure failure) => failure.message,
            'message',
            kAiChatPlanAudioUnsupported,
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test(
    'model catalog exposes only account-visible ChatGPT-plan models',
    () async {
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        planAccessTokenResolver: (_) async => 'access-token',
        client: MockClient((http.Request request) async {
          expect(request.url, Uri.parse('https://api.openai.com/v1/models'));
          expect(request.headers['authorization'], 'Bearer access-token');
          return http.Response(
            jsonEncode(<String, Object?>{
              'models': <Map<String, Object?>>[
                <String, Object?>{'slug': 'gpt-visible', 'visibility': 'list'},
                <String, Object?>{
                  'slug': 'gpt-hidden',
                  'visibility': 'internal',
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      expect(await client.listModels(_planProvider()), <String>['gpt-visible']);
    },
  );
}
