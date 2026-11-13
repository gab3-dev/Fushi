import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

void main() {
  test('v147 allows paused manga jobs and preserves existing rows', () async {
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
CREATE TABLE manga_download_jobs (
  job_id TEXT NOT NULL PRIMARY KEY,
  kind TEXT NOT NULL,
  book_key TEXT NOT NULL,
  chapter_key TEXT NOT NULL,
  runtime TEXT NOT NULL,
  title TEXT NOT NULL,
  chapter_title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  pages_done INTEGER NOT NULL DEFAULT 0,
  pages_total INTEGER NOT NULL DEFAULT 0,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  auto_ocr INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER,
  CHECK (job_id != '' AND book_key != '' AND chapter_key != '' AND runtime != ''),
  CHECK (kind IN ('chapter', 'mokuro_volume')),
  CHECK (status IN ('queued', 'running', 'done', 'failed', 'cancelled')),
  CHECK (pages_done >= 0 AND pages_total >= 0 AND pages_done <= pages_total),
  CHECK (attempt_count >= 0)
)
''');
          rawDb.execute('''
INSERT INTO manga_download_jobs
  (job_id, kind, book_key, chapter_key, runtime, title, chapter_title,
   status, pages_done, pages_total, created_at, updated_at)
VALUES ('job-1', 'chapter', 'book-1', '/chapter/1', 'mihon',
        'Series', 'Chapter 1', 'running', 2, 3, 100, 101)
''');
          rawDb.execute('PRAGMA user_version = 146');
        },
      ),
    );
    addTearDown(database.close);

    final MangaDownloadJobRow existing =
        (await database.getMangaDownloadJob('job-1'))!;
    expect(existing.status, MangaDownloadJobStatus.running);
    expect(existing.pagesDone, 2);
    expect(existing.pagesTotal, 3);

    await database.updateMangaDownloadJobStatus(
      'job-1',
      status: MangaDownloadJobStatus.paused,
      updatedAt: 200,
    );
    final MangaDownloadJobRow paused =
        (await database.getMangaDownloadJob('job-1'))!;
    expect(paused.status, MangaDownloadJobStatus.paused);
    expect(paused.pagesDone, 2);
    expect(paused.pagesTotal, 3);
  });
}
