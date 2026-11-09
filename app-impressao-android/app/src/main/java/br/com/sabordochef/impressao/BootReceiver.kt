package br.com.sabordochef.impressao

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return

        val token = context.getSharedPreferences("printer_config", Context.MODE_PRIVATE)
            .getString("device_token", "").orEmpty()
        if (token.length < 32) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT)
            != PackageManager.PERMISSION_GRANTED
        ) return

        try {
            ContextCompat.startForegroundService(
                context,
                Intent(context, PrintService::class.java)
            )
        } catch (_: Exception) {
            // O usuário ainda pode iniciar a central pelo ícone do aplicativo.
        }
    }
}
