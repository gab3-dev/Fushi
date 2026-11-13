package app.fushi.reader.mihon

import android.app.Application
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.protobuf.ProtoBuf
import uy.kohesive.injekt.api.InjektScope
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.registry.default.DefaultRegistrar
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertSame

@OptIn(ExperimentalSerializationApi::class)
class MihonInjektModuleTest {
    @Test
    fun serializersUsedByExtensionsAreResolvable() {
        val injekt = InjektScope(DefaultRegistrar()).apply {
            importModule(mihonInjektModule(Application()))
        }

        assertNotNull(injekt.get<Json>())
        assertSame(ProtoBuf, injekt.get<ProtoBuf>())
    }
}
