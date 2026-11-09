# Teste da central de impressão 0.2.0

## Antes de instalar
- Pareie a impressora Bluetooth com o nome esperado pelo aplicativo: `Bluetooth Printer`.
- Mantenha o código de conexão já salvo no Android.
- Autorize **Dispositivos próximos** e notificações.
- Configure a bateria do aplicativo como **Sem restrições**.

## Testes de fila
1. Com a central ativa e a impressora ligada, aceite um pedido de delivery e confira as duas vias.
2. Desligue a impressora, aceite outro pedido e confira no painel se a tarefa permanece aguardando nova tentativa.
3. Ligue novamente a impressora e aguarde a reimpressão automática.
4. Feche e abra o aplicativo; confirme que a central retoma o serviço.
5. Reinicie o Android e confira se a central volta a iniciar após o desbloqueio e as permissões do sistema.
6. No painel, abra **Central de impressão > Últimas impressões** e confira estado, tentativas e mensagem de erro.

## Teste de formatação
- Confira nomes de produtos e observações com ã, ç, é, ó e õ.
- Confira a linha `TOTAL: R$ 00,00` sem caracteres extras.
- Confira que a via do entregador não exibe “ENTREGA GRÁTIS”.
- Confira que o pagamento aparece como Dinheiro na entrega, Pix na entrega ou Cartão na entrega.

## Limite de confirmação
O estado **Enviado à impressora** confirma que o APK enviou os dados pela conexão Bluetooth e recebeu confirmação do serviço no Supabase. Impressoras Bluetooth ESC/POS genéricas normalmente não confirmam ao aplicativo que o papel saiu fisicamente ou que não houve falta de papel durante a impressão. Por isso, o painel não deve ser interpretado como sensor físico de papel.
