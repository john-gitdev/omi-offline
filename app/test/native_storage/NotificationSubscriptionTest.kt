private const val ADDRESS = "AA:BB"
private const val SERVICE = "30295780-4301-eabd-2904-2849adfeae43"
private const val CHAR = "30295781-4301-eabd-2904-2849adfeae43"

private class Fixture {
    val manager = OmiBleManager()
    val gatt = BluetoothGatt(Device(ADDRESS))
    val results = mutableListOf<Result<Unit>>()
    init { manager.connectedGatts[ADDRESS] = gatt }
    fun subscribe() = manager.subscribeCharacteristic(ADDRESS, SERVICE, CHAR) { results.add(it) }
    fun reply(status: Int = 0, connection: BluetoothGatt = gatt) =
        manager.onDescriptorWrite(connection, connection.characteristic.descriptor!!, status)
    fun failure() {
        check(results.size == 1 && results.single().isFailure)
        check((results.single().exceptionOrNull() as FlutterError).code == "notification-subscription")
    }
}
fun main() {
    var passed = 0
    fun case(name: String, run: () -> Unit) { run(); passed++; println("PASS: $name") }

    case("wait for descriptor callback, not queue submission") {
        val f = Fixture(); f.subscribe()
        check(f.results.isEmpty()); f.manager.issue()
        check(f.results.isEmpty()); f.reply()
        check(f.results.single().isSuccess)
    }
    case("missing connection is an error") {
        val f = Fixture(); f.manager.connectedGatts.clear(); f.subscribe(); f.failure()
    }
    case("missing descriptor is an error") {
        val f = Fixture(); f.gatt.characteristic.descriptor = null; f.subscribe(); f.failure()
    }
    case("local registration rejection is an error") {
        val f = Fixture(); f.gatt.localAccepted = false; f.subscribe(); f.manager.issue()
        f.failure(); check(f.gatt.writes == 0); check(f.manager.completedCommands == 1)
    }
    case("immediate descriptor rejection is an error") {
        val f = Fixture(); f.gatt.descriptorAccepted = false; f.subscribe(); f.manager.issue(); f.failure()
    }
    case("descriptor callback failure is propagated") {
        val f = Fixture(); f.subscribe(); f.manager.issue(); f.reply(5); f.failure()
    }
    case("disconnect fails a pending subscription once") {
        val f = Fixture(); f.subscribe(); f.manager.issue(); f.manager.disconnect(ADDRESS)
        f.failure(); f.reply(); check(f.results.size == 1)
    }
    case("old connection callback cannot confirm a replacement subscription") {
        val f = Fixture(); f.subscribe(); f.manager.issue(); f.manager.disconnect(ADDRESS)
        val replacement = BluetoothGatt(Device(ADDRESS))
        f.manager.connectedGatts[ADDRESS] = replacement
        f.subscribe(); f.manager.issue(); f.reply()
        check(f.results.size == 1)
        f.reply(connection = replacement)
        check(f.results.size == 2 && f.results.last().isSuccess)
    }
    case("preceding descriptor callback cannot confirm a queued subscription") {
        val f = Fixture(); f.subscribe(); f.reply()
        check(f.results.isEmpty())
        f.manager.issue(); f.reply(); check(f.results.single().isSuccess)
    }
    case("an unsuccessful subscription can be retried") {
        val f = Fixture(); f.gatt.localAccepted = false; f.subscribe(); f.manager.issue(); f.failure()
        f.gatt.localAccepted = true; f.subscribe(); f.manager.issue(); f.reply()
        check(f.results.size == 2 && f.results.last().isSuccess)
    }
    case("legacy Android descriptor path also waits for confirmation") {
        android.os.Build.VERSION.SDK_INT = 32
        val f = Fixture(); f.subscribe(); f.manager.issue()
        check(f.results.isEmpty()); f.reply(); check(f.results.single().isSuccess)
        android.os.Build.VERSION.SDK_INT = 33
    }
    case("registration exceptions are surfaced") {
        val f = Fixture(); f.gatt.throwRegistration = true; f.subscribe(); f.manager.issue(); f.failure()
    }
    println("$passed notification subscription tests passed")
}
