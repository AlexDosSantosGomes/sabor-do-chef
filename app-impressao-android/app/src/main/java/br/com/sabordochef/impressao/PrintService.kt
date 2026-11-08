package br.com.sabordochef.impressao

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.text.NumberFormat
import java.util.Locale
import kotlin.concurrent.thread

class PrintService : Service() {
    @Volatile private var running = false
    private var worker: Thread? = null
    private var cpuWakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        // Mantém a CPU ativa durante a impressão mesmo com a tela apagada.
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        cpuWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "SaborDoChef:PrintService"
        ).apply { acquire() }
        startForeground(NOTIFICATION_ID, buildNotification("Central ativa — aguardando pedidos"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running) {
            running = true
            worker = thread(name = "sabor-print-queue") { pollQueue() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        cpuWakeLock?.let { if (it.isHeld) it.release() }
        cpuWakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun pollQueue() {
        val token = getSharedPreferences("printer_config", MODE_PRIVATE)
            .getString("device_token", "").orEmpty()
        if (token.length < 32) {
            updateNotification("Código de conexão não configurado")
            stopSelf()
            return
        }

        while (running && !Thread.currentThread().isInterrupted) {
            try {
                val response = api(token, JSONObject().put("action", "claim"))
                if (response.has("error")) throw IllegalStateException(response.optString("error"))
                val job = response.optJSONObject("job")
                if (job == null || job.length() == 0) {
                    updateNotification("Central ativa — aguardando pedidos")
                    Thread.sleep(8000)
                    continue
                }

                val jobId = job.getString("id")
                try {
                    val bytes = buildTickets(job)
                    RawBtBridge.sendEscPos(this, bytes)
                    api(token, JSONObject().put("action", "complete").put("job_id", jobId))
                    updateNotification("Pedido #${job.optJSONObject("order")?.optString("order_number") ?: ""} enviado ao RawBT")
                    Thread.sleep(2500)
                } catch (printError: Exception) {
                    try {
                        api(token, JSONObject()
                            .put("action", "fail")
                            .put("job_id", jobId)
                            .put("error", printError.message ?: "Falha ao enviar para RawBT"))
                    } catch (_: Exception) { }
                    updateNotification("Falha no envio. Verifique RawBT e impressora.")
                    Thread.sleep(6000)
                }
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (e: Exception) {
                updateNotification("Sem conexão ou erro na fila. Tentando novamente.")
                try { Thread.sleep(10000) } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
    }

    private fun api(token: String, body: JSONObject): JSONObject {
        val connection = (URL(API_URL).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15000
            readTimeout = 20000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("x-device-token", token)
        }
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            val json = if (text.isBlank()) JSONObject() else JSONObject(text)
            if (code !in 200..299) throw IllegalStateException(json.optString("error", "Erro HTTP $code"))
            return json
        } finally {
            connection.disconnect()
        }
    }

    private fun buildTickets(job: JSONObject): ByteArray {
        val order = job.getJSONObject("order")
        val items = job.optJSONArray("items")
        val accompaniments = job.optJSONArray("accompaniments")
        val accByItem = mutableMapOf<String, MutableList<String>>()
        if (accompaniments != null) {
            for (i in 0 until accompaniments.length()) {
                val acc = accompaniments.getJSONObject(i)
                val key = acc.optString("order_item_id")
                accByItem.getOrPut(key) { mutableListOf() }.add(acc.optString("accompaniment_name"))
            }
        }

        val number = order.optString("order_number", "—")
        val kitchen = StringBuilder()
        kitchen.append("SABOR DO CHEF\n")
            .append("VIA COZINHA\n")
            .append("--------------------------------\n")
            .append("PEDIDO #").append(number).append("\n")
            .append("CLIENTE: ").append(order.optString("customer_name", "—")).append("\n")
            .append("--------------------------------\n")
        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                kitchen.append(item.optInt("quantity", 1)).append("x ")
                    .append(item.optString("product_name_snapshot")).append("\n")
                accByItem[item.optString("id")]?.forEach { kitchen.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") kitchen.append("  Obs: ").append(notes).append("\n")
            }
        }
        val customerNotes = order.optString("customer_notes")
        if (customerNotes.isNotBlank() && customerNotes != "null") {
            kitchen.append("--------------------------------\nOBS: ").append(customerNotes).append("\n")
        }
        kitchen.append("\n\n")

        val currency = NumberFormat.getCurrencyInstance(Locale("pt", "BR"))
            .format(order.optInt("total_cents", 0) / 100.0)
        val courier = StringBuilder()
            .append("SABOR DO CHEF\n")
            .append("VIA ENTREGADOR\n")
            .append("--------------------------------\n")
            .append("PEDIDO #").append(number).append("\n")
            .append("CLIENTE: ").append(order.optString("customer_name", "—")).append("\n")
            .append("TELEFONE: ").append(order.optString("customer_phone", "—")).append("\n")
            .append("ENDERECO: ").append(order.optString("delivery_address", "—")).append("\n")
            .append("PAGAMENTO: ").append(order.optString("payment_method", "—")).append("\n")
            .append("ENTREGA: GRATIS\n")
            .append("TOTAL: ").append(currency).append("\n")
            .append("--------------------------------\n")
            .append("ITENS\n")
        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                courier.append(item.optInt("quantity", 1)).append("x ")
                    .append(item.optString("product_name_snapshot")).append("\n")
                accByItem[item.optString("id")]?.forEach { courier.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") courier.append("  Obs: ").append(notes).append("\n")
            }
        }
        courier.append("\n\n")

        val out = java.io.ByteArrayOutputStream()
        out.write(kitchen.toString().toByteArray(Charsets.UTF_8))
        out.write(byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00))
        out.write(courier.toString().toByteArray(Charsets.UTF_8))
        out.write(byteArrayOf(0x1B, 0x64, 0x03))
        return out.toByteArray()
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Central de impressão", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(message: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle("Sabor do Chef")
            .setContentText(message)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    companion object {
        private const val API_URL = "https://enakuleybfvzqurrttwl.supabase.co/functions/v1/printer-device-api"
        private const val CHANNEL_ID = "sabor_do_chef_print_service"
        private const val NOTIFICATION_ID = 4107
    }
}