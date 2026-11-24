package br.com.sabordochef.impressao

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
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
    @Volatile private var connectedSocket: BluetoothSocket? = null
    @Volatile private var pairedPrinter: BluetoothDevice? = null

    @Synchronized
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
        if (!adapter.isEnabled) {
            closeLocked()
            throw IOException("Ative o Bluetooth do Android.")
        }

        try {
            var socket = connectedSocket
            if (socket == null || !socket.isConnected) {
                closeLocked()
                val device = pairedPrinter ?: adapter.bondedDevices.firstOrNull {
                    it.name?.equals(PRINTER_NAME, ignoreCase = true) == true
                }?.also { pairedPrinter = it } ?: throw IOException(
                    "Não encontrei '$PRINTER_NAME' entre os dispositivos pareados. Pareie a impressora novamente e confira o nome."
                )

                // Mantém o canal SPP aberto entre os pedidos para reduzir o tempo de conexão.
                // Não chamamos cancelDiscovery(): não é necessário para estabelecer a conexão.
                socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                socket.connect()
                connectedSocket = socket
            }

            socket.outputStream.write(bytes)
            socket.outputStream.flush()
        } catch (error: Exception) {
            closeLocked()
            pairedPrinter = null
            if (error is IOException) throw error
            throw IOException(error.message ?: "Falha na conexão Bluetooth.", error)
        }
    }

    @Synchronized
    fun close() {
        closeLocked()
    }

    private fun closeLocked() {
        try { connectedSocket?.close() } catch (_: Exception) { }
        connectedSocket = null
    }
}
