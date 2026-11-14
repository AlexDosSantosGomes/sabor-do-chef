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
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
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
                val prefs = getSharedPreferences("printer_config", MODE_PRIVATE)
                val pendingAckId = prefs.getString("pending_ack_job_id", null)
                if (!pendingAckId.isNullOrBlank()) {
                    if (confirmSentJob(token, pendingAckId)) Thread.sleep(1500)
                    else Thread.sleep(8000)
                    continue
                }

                val response = api(token, JSONObject().put("action", "claim"))
                if (response.has("error")) throw IllegalStateException(response.optString("error"))
                val job = response.optJSONObject("job")
                if (job == null || job.length() == 0) {
                    updateNotification("Central ativa — aguardando pedidos")
                    Thread.sleep(25000)
                    continue
                }

                val jobId = job.getString("id")
                try {
                    val bytes = buildTickets(job)
                    BluetoothPrinter.sendEscPos(this, bytes)
                } catch (printError: Exception) {
                    try {
                        api(token, JSONObject()
                            .put("action", "fail")
                            .put("job_id", jobId)
                            .put("error", printError.message ?: "Falha ao enviar via Bluetooth"))
                    } catch (_: Exception) { }
                    updateNotification("Impressora indisponível. Pedido guardado para nova tentativa.")
                    Thread.sleep(8000)
                    continue
                }

                // Salva o ACK antes de qualquer nova busca. Se a internet cair após o envio,
                // o APK confirma a tarefa sem mandar a mesma nota novamente.
                prefs.edit().putString("pending_ack_job_id", jobId).apply()
                if (confirmSentJob(token, jobId)) Thread.sleep(1500)
                else Thread.sleep(8000)
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

    private fun confirmSentJob(token: String, jobId: String): Boolean {
        return try {
            api(token, JSONObject().put("action", "complete").put("job_id", jobId))
            getSharedPreferences("printer_config", MODE_PRIVATE)
                .edit().remove("pending_ack_job_id").apply()
            updateNotification("Pedido enviado à impressora e registrado no painel")
            true
        } catch (_: Exception) {
            updateNotification("Nota enviada; aguardando confirmação do painel.")
            false
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

        if (order.optString("order_type").equals("PICKUP", ignoreCase = true)) {
            return buildPickupTickets(order, items, accByItem)
        }

        val number = order.optString("order_number", "N/I")
        val totalCents = order.optInt("total_cents", 0)
        val changeForCents = order.optInt("change_for_cents", 0)
        val hasChange = order.optBoolean("needs_change") || changeForCents > totalCents
        val amountFormat = NumberFormat.getNumberInstance(Locale("pt", "BR")).apply {
            minimumFractionDigits = 2
            maximumFractionDigits = 2
        }
        fun brl(cents: Int) = "R$ " + amountFormat.format(cents / 100.0)
        val total = brl(totalCents)
        val payment = when (order.optString("payment_method").uppercase(Locale.ROOT)) {
            "CASH" -> "Dinheiro na entrega"
            "PIX" -> "Pix na entrega"
            "CARD" -> "Cartão na entrega"
            "PAGAMENTO_NA_ENTREGA" -> "Pagamento na entrega"
            else -> order.optString("payment_method", "Pagamento na entrega").replace("_", " ")
        }
        val createdAt = order.optString("created_at")
        val createdInstant = try { Instant.parse(createdAt) } catch (_: Exception) { null }
        val localDate = createdInstant?.atZone(ZoneId.of("America/Sao_Paulo"))
        val dateTime = localDate?.format(DateTimeFormatter.ofPattern("dd/MM/yyyy 'às' HH:mm", Locale("pt", "BR")))
            ?: "Data e horário não disponíveis"
        val customerNotes = order.optString("customer_notes").takeUnless { it == "null" }.orEmpty()
        val itemLines = buildString {
            if (items != null) {
                for (i in 0 until items.length()) {
                    val item = items.getJSONObject(i)
                    append(item.optInt("quantity", 1)).append("x ")
                        .append(item.optString("product_name_snapshot")).append("\n")
                    accByItem[item.optString("id")]?.forEach { append("  + ").append(it).append("\n") }
                    val notes = item.optString("notes")
                    if (notes.isNotBlank() && notes != "null") append("  Obs.: ").append(notes).append("\n")
                }
            }
        }

        // As duas vias compartilham exatamente o mesmo conteúdo; somente o título muda.
        fun buildCopy(title: String) = buildString {
            append("SABOR DO CHEF\n")
                .append(title).append("\n")
                .append("--------------------------------\n")
                .append("PEDIDO Nº ").append(number).append("\n")
                .append("DATA/HORA: ").append(dateTime).append("\n")
                .append("CLIENTE: ").append(order.optString("customer_name", "Não informado")).append("\n")
                .append("TELEFONE: ").append(order.optString("customer_phone", "Não informado")).append("\n")
                .append("ENDEREÇO: ").append(order.optString("delivery_address", "Não informado")).append("\n")
                .append("PAGAMENTO: ").append(payment).append("\n")
                .append("TOTAL: ").append(total).append("\n")
            if (hasChange) {
                append("VAI PAGAR COM: ").append(brl(changeForCents)).append("\n")
                    .append("TROCO: ").append(brl(changeForCents - totalCents)).append("\n")
            }
            if (customerNotes.isNotBlank()) {
                append("OBSERVAÇÃO DO CLIENTE: ").append(customerNotes).append("\n")
            }
            append("--------------------------------\n")
                .append("ITENS DO PEDIDO\n")
                .append(itemLines)
                .append("--------------------------------\n\n\n")
        }

        val cashierCopy = PrinterText.encode(buildCopy("VIA DO CAIXA"))
        val courierCopy = PrinterText.encode(buildCopy("VIA DO MOTOBOY"))
        val cut = byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00)
        val out = java.io.ByteArrayOutputStream()
        out.write(PrinterText.initialize())
        out.write(cashierCopy)
        out.write(cut)
        out.write(courierCopy)
        out.write(cut)
        return out.toByteArray()
    }

    private fun buildPickupTickets(
        order: JSONObject,
        items: org.json.JSONArray?,
        accByItem: Map<String, List<String>>
    ): ByteArray {
        val number = order.optString("order_number", "N/I")
        val createdAt = order.optString("created_at")
        val createdInstant = try { Instant.parse(createdAt) } catch (_: Exception) { null }
        val localDate = createdInstant?.atZone(ZoneId.of("America/Sao_Paulo"))
        val date = localDate?.format(DateTimeFormatter.ofPattern("dd/MM/yyyy", Locale("pt", "BR"))) ?: "Data não disponível"
        val time = localDate?.format(DateTimeFormatter.ofPattern("HH:mm", Locale("pt", "BR"))) ?: "Horário não disponível"
        val amountFormat = NumberFormat.getNumberInstance(Locale("pt", "BR")).apply {
            minimumFractionDigits = 2
            maximumFractionDigits = 2
        }
        val total = "R$ " + amountFormat.format(order.optInt("total_cents", 0) / 100.0)
        val payment = when (order.optString("payment_method").uppercase(Locale.ROOT)) {
            "CASH" -> "DINHEIRO"
            "PIX" -> "PIX"
            "CARD" -> "CARTÃO"
            else -> order.optString("payment_method", "Não informado").uppercase(Locale("pt", "BR"))
        }

        val ticket = StringBuilder()
            .append("SABOR DO CHEF\n")
            .append("COMANDA DE PEDIDO\n")
            .append("================================\n")
            .append("              RETIRADA\n")
            .append("================================\n")
            .append("PEDIDO Nº ").append(number).append("\n")
            .append("Data: ").append(date).append("\n")
            .append("Horário do pedido: ").append(time).append("\n")
            .append("Cliente: ").append(order.optString("customer_name", "Não informado")).append("\n")
            .append("Telefone: ").append(order.optString("customer_phone", "Não informado")).append("\n")
            .also { val notes = order.optString("customer_notes"); if (notes.isNotBlank() && notes != "null") it.append("Observação: ").append(notes).append("\n") }
            .append("--------------------------------\n")
            .append("PRODUTOS\n")

        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                ticket.append(item.optInt("quantity", 1)).append("x ")
                    .append(item.optString("product_name_snapshot")).append("\n")
                accByItem[item.optString("id")]?.forEach { ticket.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") ticket.append("  Obs: ").append(notes).append("\n")
            }
        }

        if (order.optBoolean("needs_change") || order.optInt("change_for_cents", 0) > order.optInt("total_cents", 0)) {
            val changeFor = order.optInt("change_for_cents", 0)
            val changeDue = changeFor - order.optInt("total_cents", 0)
            ticket.append("--------------------------------\n")
                .append("Vai pagar com: R$ ").append(amountFormat.format(changeFor / 100.0)).append("\n")
                .append("Troco: R$ ").append(amountFormat.format(changeDue / 100.0)).append("\n")
        }

        ticket.append("--------------------------------\n")
            .append("TOTAL ").append(total).append("\n")
            .append("FORMA DE PAGAMENTO: ").append(payment).append("\n")
            .append("PAGAMENTO NA RETIRADA\n")
            .append("\n\n")

        val copy = PrinterText.encode(ticket.toString())
        val cut = byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00)
        val out = java.io.ByteArrayOutputStream()
        out.write(PrinterText.initialize())
        out.write(copy)
        out.write(cut)
        out.write(copy)
        out.write(cut)
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
