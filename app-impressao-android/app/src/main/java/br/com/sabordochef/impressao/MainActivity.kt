package br.com.sabordochef.impressao

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    private lateinit var serviceStatus: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestRuntimePermissions()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(40, 56, 40, 40)
        }

        val title = TextView(this).apply {
            text = "SABOR DO CHEF"
            textSize = 25f
            setTextColor(0xFFB5121B.toInt())
        }
        val subtitle = TextView(this).apply {
            text = "Central de impressão"
            textSize = 18f
            setPadding(0, 8, 0, 32)
        }
        serviceStatus = TextView(this).apply {
            text = "Serviço de impressão: parado"
            textSize = 16f
            setPadding(0, 0, 0, 24)
        }
        val start = Button(this).apply {
            text = "Iniciar serviço"
            setOnClickListener {
                ContextCompat.startForegroundService(
                    this@MainActivity,
                    Intent(this@MainActivity, PrintService::class.java)
                )
                serviceStatus.text = "Serviço de impressão: iniciado"
            }
        }
        val stop = Button(this).apply {
            text = "Parar serviço"
            setOnClickListener {
                stopService(Intent(this@MainActivity, PrintService::class.java))
                serviceStatus.text = "Serviço de impressão: parado"
            }
        }
        val note = TextView(this).apply {
            text = "Mantenha este aparelho ligado, conectado à internet e pareado com a impressora. A conexão remota com os pedidos será ativada na próxima etapa."
            textSize = 14f
            setPadding(0, 28, 0, 0)
        }

        root.addView(title)
        root.addView(subtitle)
        root.addView(serviceStatus)
        root.addView(start)
        root.addView(stop)
        root.addView(note)
        setContentView(root)
    }

    private fun requestRuntimePermissions() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                100
            )
        }
    }
}
