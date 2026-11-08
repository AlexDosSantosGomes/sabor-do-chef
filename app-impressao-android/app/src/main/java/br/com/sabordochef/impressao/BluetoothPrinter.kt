package br.com.sabordochef.impressao

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.IOException
import java.util.UUID

object BluetoothPrinter {
    private const val PRINTER_NAME = "Bluetooth Printer"
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    @Suppress("MissingPermission")
    fun sendEscPos(context: Context, bytes: ByteArray) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("Permita o acesso a Dispositivos próximos nas configurações do Android.")
        }

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter = manager.adapter
            ?: throw IOException("Este Android não possui Bluetooth.")
        if (!adapter.isEnabled) throw IOException("Ative o Bluetooth do Android.")

        val device = adapter.bondedDevices.firstOrNull {
            it.name?.equals(PRINTER_NAME, ignoreCase = true) == true
        } ?: throw IOException(
            "Não encontrei '$PRINTER_NAME' entre os dispositivos pareados. Pareie a impressora novamente e confira o nome."
        )

        var socket: BluetoothSocket? = null
        try {
            // Não chamamos cancelDiscovery(): essa operação exige BLUETOOTH_SCAN
            // no Android 12+, e não é necessária para estabelecer a conexão SPP.
            socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
            socket.connect()
            socket.outputStream.use { output ->
                output.write(bytes)
                output.flush()
            }
        } finally {
            try { socket?.close() } catch (_: Exception) { }
        }
    }
}
