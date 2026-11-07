# Sabor do Chef — aplicativo de impressão Android

Aplicativo Android nativo para manter o ponto de impressão do restaurante ativo e encaminhar trabalhos ao RawBT.

## Estado do projeto

Esta é a primeira etapa: estrutura Android, tela de estado, serviço em primeiro plano e ponte de impressão RawBT. **Ainda não recebe pedidos do Supabase**. A integração remota será adicionada depois de definir e testar a autenticação exclusiva do dispositivo.

O painel atual e o botão manual de impressão permanecem intactos.

## Requisitos

- Android 8.0 ou superior (API 26+).
- RawBT instalado no aparelho.
- Impressora Goldensky pareada no Android.
- Internet ativa para a futura fila remota.

## Segurança

Não colocar a chave `service_role`, senha de administrador ou segredo do Supabase no aplicativo. A próxima etapa usará uma credencial própria do dispositivo validada no servidor.

## Compilar

Abra esta pasta no Android Studio, aguarde a sincronização do Gradle e gere um APK de depuração para os primeiros testes.

## Teste inicial

1. Instale o RawBT e confirme a impressão de teste diretamente nele.
2. Instale o APK de depuração.
3. Abra o Sabor do Chef — Impressão e toque em **Iniciar serviço**.
4. Confirme que a notificação persistente aparece.
5. A etapa seguinte adicionará o pareamento seguro com a fila de impressão e um teste controlado de impressão.
