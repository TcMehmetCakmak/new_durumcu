-- DÜRÜMCÜ - GERÇEK WHATSAPP OTP İLE TELEFON DOĞRULAMA
-- Supabase SQL Editor'da BİR KEZ çalıştırın.
-- Ön koşul: Supabase Authentication > Phone provider altında Twilio/Twilio Verify
-- yapılandırılmalı ve WhatsApp sender etkin olmalıdır.

-- Eski, kodu frontend'e döndüren özel doğrulama akışını kapat.
do $$ begin
  revoke execute on function public.begin_phone_whatsapp_verification(text) from anon, authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_verified_order_with_coupons(
    text,text,text,text,numeric,numeric,text,jsonb,text[],text,uuid,text
  ) from anon, authenticated;
exception when undefined_function then null; end $$;

-- Telefon numarası artık frontend parametresinden değil,
-- Supabase Auth tarafından doğrulanmış JWT'deki phone claim'inden alınır.
create or replace function public.create_phone_verified_order_with_coupons(
  p_name text,
  p_address text,
  p_payment text,
  p_note text default '',
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_google_maps_url text default '',
  p_items jsonb default '[]'::jsonb,
  p_coupon_codes text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_phone text := coalesce(auth.jwt()->>'phone','');
  v_uid uuid := auth.uid();
  r jsonb;
  v_id bigint;
begin
  if v_uid is null then
    raise exception 'Telefon doğrulaması gerekli.';
  end if;

  -- Uygulama Türkiye cep telefonu numarası bekliyor.
  if v_phone !~ '^\\+90[0-9]{10}$' then
    raise exception 'Doğrulanmış Türkiye telefon numarası bulunamadı.';
  end if;

  r := public.create_order_with_coupons(
    p_name,
    p_address,
    p_payment,
    p_note,
    p_latitude,
    p_longitude,
    p_google_maps_url,
    p_items,
    p_coupon_codes
  );

  v_id := (r->>'id')::bigint;

  update public.orders
     set phone_number = v_phone,
         verification_method = 'phone-whatsapp-otp',
         verified_at = now(),
         status = 'devam-ediyor'
   where id = v_id;

  return r || jsonb_build_object(
    'phone_number', v_phone,
    'verification_method', 'phone-whatsapp-otp',
    'verified_at', now(),
    'status', 'devam-ediyor'
  );
end;
$$;

revoke all on function public.create_phone_verified_order_with_coupons(
  text,text,text,text,numeric,numeric,text,jsonb,text[]
) from public;

grant execute on function public.create_phone_verified_order_with_coupons(
  text,text,text,text,numeric,numeric,text,jsonb,text[]
) to authenticated;

-- Eski doğrudan sipariş RPC'leri doğrulamayı atlayamasın.
do $$ begin
  revoke execute on function public.create_order_with_coupons(
    text,text,text,text,numeric,numeric,text,jsonb,text[]
  ) from anon, authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_order_with_coupon(
    text,text,text,text,numeric,numeric,text,jsonb,text
  ) from anon, authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_order(
    text,text,text,text,numeric,numeric,text,jsonb
  ) from anon, authenticated;
exception when undefined_function then null; end $$;
