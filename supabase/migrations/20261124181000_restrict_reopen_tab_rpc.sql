revoke all on function public.reopen_dining_tab_after_payment_cancel(uuid) from public;
revoke all on function public.reopen_dining_tab_after_payment_cancel(uuid) from anon;
grant execute on function public.reopen_dining_tab_after_payment_cancel(uuid) to authenticated;