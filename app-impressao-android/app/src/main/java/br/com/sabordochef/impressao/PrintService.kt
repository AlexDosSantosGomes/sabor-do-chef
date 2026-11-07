package br.com.sabordochef.impressao

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class PrintService : Service() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A conexão segura com a fila remota será ligada nesta etapa inicial.
        // O serviço já fica em primeiro plano para permitir o trabalho contínuo.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Central de impressão",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Mantém o serviço de impressão do Sabor do Chef ativo"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_print)
            .setContentTitle("Sabor do Chef")
            .setContentText("Central de impressão ativa — integração remota em preparação")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    companion object {
        private const val CHANNEL_ID = "sabor_do_chef_print_service"
        private const val NOTIFICATION_ID = 4107
    }
}
