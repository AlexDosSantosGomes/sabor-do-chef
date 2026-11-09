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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Mantém um socket SPP aberto entre pedidos. A conexão é criada sob demanda
 * pelo serviço e só é fechada quando cai, falha ou o serviço é encerrado.
 */
object BluetoothPrinter {
    private const val PRINTER_NAME = "Bluetooth Printer"
    private const val CONNECT_TIMEOUT_SECONDS = 10L
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val lock = Any()

    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var connecting = false

    enum class State { DISCONNECTED, CONNECTING, CONNECTED }

    fun state(): State = when {
        connecting -> State.CONNECTING
        socket?.let { it.isConnected && !it.isClosed } == true -> State.CONNECTED
        else -> State.DISCONNECTED
    }

    @Suppress("MissingPermission")
    fun connect(context: Context) {
        synchronized(lock) {
            if (state() == State.CONNECTED) return
            connecting = true
            closeSocketLocked()
            var candidate: BluetoothSocket? = null
            val executor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "sabor-bt-connect").apply { isDaemon = true }
            }
            try {
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
                    "Não encontrei '$PRINTER_NAME' entre os dispositivos pareados. Confira o pareamento."
                )

                // O socket candidato é fechado também se o limite de conexão expirar.
                candidate = device.createRfcommSocketToServiceRecord(SPP_UUID)
                val connectingSocket = candidate
                val future = executor.submit { connectingSocket.connect() }
                try {
                    future.get(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                } catch (timeout: TimeoutException) {
                    future.cancel(true)
                    try { connectingSocket.close() } catch (_: Exception) { }
                    throw IOException("Tempo limite de 10 segundos ao conectar à impressora.")
                }

                socket = connectingSocket
            } catch (e: Exception) {
                try { candidate?.close() } catch (_: Exception) { }
                socket = null
                throw if (e is IOException || e is SecurityException) e
                else IOException(e.message ?: "Não foi possível conectar à impressora.", e)
            } finally {
                connecting = false
                executor.shutdownNow()
            }
        }
    }

    fun sendEscPos(context: Context, bytes: ByteArray) {
        if (state() != State.CONNECTED) connect(context)
        val active = socket ?: throw IOException("A conexão Bluetooth não está disponível.")
        try {
            // Não usar use{}: fechar o stream encerraria a conexão persistente.
            active.outputStream.write(bytes)
            active.outputStream.flush()
        } catch (e: Exception) {
            disconnect()
            throw IOException(e.message ?: "Falha ao enviar dados à impressora.", e)
        }
    }

    fun disconnect() {
        synchronized(lock) { closeSocketLocked() }
    }

    private fun closeSocketLocked() {
        try { socket?.close() } catch (_: Exception) { }
        socket = null
    }
}
