package br.com.sabordochef.impressao

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private lateinit var tokenInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestRuntimePermissions()

        val prefs = getSharedPreferences("printer_config", MODE_PRIVATE)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(40, 48, 40, 40)
        }
        root.addView(TextView(this).apply {
            text = "SABOR DO CHEF"
            textSize = 25f
            setTextColor(0xFFB5121B.toInt())
        })
        root.addView(TextView(this).apply {
            text = "Central de impressão"
            textSize = 18f
            setPadding(0, 8, 0, 24)
        })
        root.addView(TextView(this).apply {
            text = "Código de conexão do aparelho"
            textSize = 14f
        })
        tokenInput = EditText(this).apply {
            hint = "Cole aqui o código fornecido"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(prefs.getString("device_token", ""))
        }
        root.addView(tokenInput)
        root.addView(Button(this).apply {
            text = "Salvar conexão"
            setOnClickListener {
                val token = tokenInput.text.toString().trim()
                if (token.length < 32) {
                    status.text = "Código inválido. Confira o código recebido."
                } else {
                    prefs.edit().putString("device_token", token).apply()
                    status.text = "Código salvo neste aparelho."
                }
            }
        })
        status = TextView(this).apply {
            text = "Serviço de impressão: parado"
            textSize = 15f
            setPadding(0, 18, 0, 18)
        }
        root.addView(status)
        root.addView(Button(this).apply {
            text = "Iniciar central de impressão"
            setOnClickListener {
                val token = prefs.getString("device_token", "").orEmpty()
                if (token.length < 32) {
                    status.text = "Primeiro salve o código de conexão."
                } else if (Build.VERSION.SDK_INT >= 31 &&
                    ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED
                ) {
                    status.text = "Autorize o acesso a dispositivos próximos para iniciar a central."
                    ActivityCompat.requestPermissions(
                        this@MainActivity,
                        arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                        REQUEST_BLUETOOTH
                    )
                } else {
                    startPrintingService()
                }
            }
        })
        root.addView(Button(this).apply {
            text = "Configurar bateria"
            setOnClickListener {
                try {
                    startActivity(Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    status.text = "Nas configurações, permita que o Sabor do Chef use a bateria sem restrições."
                } catch (e: Exception) {
                    status.text = "Abra Configurações > Aplicativos > Sabor do Chef > Bateria e selecione Sem restrições."
                }
            }
        })
        root.addView(Button(this).apply {
            text = "Parar central"
            setOnClickListener {
                stopService(Intent(this@MainActivity, PrintService::class.java))
                status.text = "Serviço de impressão: parado"
            }
        })
        root.addView(Button(this).apply {
            text = "Teste de impressão"
            setOnClickListener {
                status.text = "Conectando à Bluetooth Printer..."
                val sample = PrinterText.initialize() +
                    PrinterText.encode("SABOR DO CHEF\nTESTE DE IMPRESSÃO\nAÇÃO - CAFÉ - CORAÇÃO\nCriado por Alex o brabo\n\n") +
                    byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00)
                thread(name = "sabor-print-test") {
                    try {
                        BluetoothPrinter.sendEscPos(this@MainActivity, sample)
                        runOnUiThread { status.text = "Teste enviado à impressora Bluetooth Printer." }
                    } catch (e: Exception) {
                        runOnUiThread {
                            status.text = "Falha no teste: ${e.message ?: "verifique a impressora e o pareamento"}"
                        }
                    }
                }
            }
        })
        root.addView(TextView(this).apply {
            text = "Deixe este Android ligado, conectado ao carregador, à internet e pareado com a impressora Bluetooth Printer. Com a central iniciada, você pode usar outros aplicativos ou apagar a tela. Para maior estabilidade, configure a bateria como Sem restrições."
            textSize = 13f
            setPadding(0, 24, 0, 0)
        })
        setContentView(root)
    }

    private fun startPrintingService() {
        try {
            ContextCompat.startForegroundService(
                this,
                Intent(this, PrintService::class.java)
            )
            status.text = "Central iniciada. Aguardando pedidos aprovados."
        } catch (e: SecurityException) {
            status.text = "Permissão necessária: autorize Dispositivos próximos nas configurações do Android."
        } catch (e: Exception) {
            status.text = "Não foi possível iniciar a central: ${e.localizedMessage ?: "tente novamente"}"
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BLUETOOTH) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startPrintingService()
            } else {
                status.text = "Permissão de dispositivos próximos negada. Ative-a para iniciar a central."
            }
        }
    }

    private fun requestRuntimePermissions() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    companion object {
        private const val REQUEST_NOTIFICATIONS = 100
        private const val REQUEST_BLUETOOTH = 101
    }
}