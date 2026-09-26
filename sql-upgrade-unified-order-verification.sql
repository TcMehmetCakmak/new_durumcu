-- DÜRÜMCÜ - TEK SİPARİŞ AKIŞI / WHATSAPP KODU İLE İŞLETME DOĞRULAMASI
-- Supabase SQL Editor'da BİR KEZ çalıştırın.

create extension if not exists pgcrypto;

alter table public.orders add column if not exists verification_method text;
alter table public.orders add column if not exists whatsapp_code_hash text;
alter table public.orders add column if not exists whatsapp_code_expires_at timestamptz;
alter table public.orders add column if not exists verified_at timestamptz;
alter table public.orders add column if not exists verification_attempts integer not null default 0;

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('onay-bekliyor','devam-ediyor','tamamlandi','iptal-edildi'));

-- Tek müşteri akışı: sipariş önce doğrulama bekliyor olarak oluşturulur.
create or replace function public.create_pending_whatsapp_order_with_coupons(
  p_name text,
  p_address text,
  p_payment text,
  p_note text default '',
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_google_maps_url text default '',
  p_items jsonb default '[]'::jsonb,
  p_coupon_codes text[] default '{}'::text[]
) returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  r jsonb;
  v_id bigint;
  v_code text:=lpad(((floor(random()*900000)+100000)::int)::text,6,'0');
begin
  r:=public.create_order_with_coupons(
    p_name,p_address,p_payment,p_note,p_latitude,p_longitude,
    p_google_maps_url,p_items,p_coupon_codes
  );
  v_id:=(r->>'id')::bigint;

  update public.orders
     set status='onay-bekliyor',
         verification_method='whatsapp-business',
         verified_at=null,
         whatsapp_code_hash=encode(extensions.digest(v_code,'sha256'),'hex'),
         whatsapp_code_expires_at=now()+interval '30 minutes',
         verification_attempts=0
   where id=v_id;

  return r || jsonb_build_object(
    'status','onay-bekliyor',
    'security_code',v_code
  );
end;
$$;

revoke all on function public.create_pending_whatsapp_order_with_coupons(
  text,text,text,text,numeric,numeric,text,jsonb,text[]
) from public;
grant execute on function public.create_pending_whatsapp_order_with_coupons(
  text,text,text,text,numeric,numeric,text,jsonb,text[]
) to anon,authenticated;

-- İşletme WhatsApp'ta gelen güvenlik kodunu admin paneline girince sipariş hazırlanır.
create or replace function public.verify_whatsapp_order(p_order_id bigint,p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  o public.orders%rowtype;
begin
  if not public.is_admin() then raise exception 'Yetkisiz işlem.'; end if;

  select * into o
  from public.orders
  where id=p_order_id
  for update;

  if not found then raise exception 'Sipariş bulunamadı.'; end if;
  if o.status<>'onay-bekliyor' then raise exception 'Sipariş doğrulama beklemiyor.'; end if;
  if o.verified_at is not null then raise exception 'Sipariş zaten doğrulanmış.'; end if;
  if o.whatsapp_code_expires_at is null or o.whatsapp_code_expires_at<now() then
    raise exception 'Güvenlik kodunun süresi doldu.';
  end if;
  if o.verification_attempts>=5 then raise exception 'Çok fazla hatalı deneme yapıldı.'; end if;

  if o.whatsapp_code_hash<>encode(extensions.digest(trim(coalesce(p_code,'')),'sha256'),'hex') then
    update public.orders
       set verification_attempts=verification_attempts+1
     where id=p_order_id;
    raise exception 'Güvenlik kodu hatalı.';
  end if;

  update public.orders
     set status='devam-ediyor',
         verified_at=now(),
         whatsapp_code_hash=null,
         whatsapp_code_expires_at=null,
         verification_attempts=0
   where id=p_order_id;

  return jsonb_build_object(
    'id',p_order_id,
    'status','devam-ediyor',
    'verified',true
  );
end;
$$;

revoke all on function public.verify_whatsapp_order(bigint,text) from public;
grant execute on function public.verify_whatsapp_order(bigint,text) to authenticated;

-- Eski telefon OTP / alternatif doğrudan sipariş akışlarını kapat.
do $$ begin
  revoke execute on function public.begin_phone_whatsapp_verification(text) from anon,authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_verified_order_with_coupons(
    text,text,text,text,numeric,numeric,text,jsonb,text[],text,uuid,text
  ) from anon,authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_phone_verified_order_with_coupons(
    text,text,text,text,numeric,numeric,text,jsonb,text[]
  ) from anon,authenticated;
exception when undefined_function then null; end $$;

-- Doğrulama akışını atlayan eski RPC'ler anonim kullanıma açık kalmasın.
do $$ begin
  revoke execute on function public.create_order_with_coupons(
    text,text,text,text,numeric,numeric,text,jsonb,text[]
  ) from anon,authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_order_with_coupon(
    text,text,text,text,numeric,numeric,text,jsonb,text
  ) from anon,authenticated;
exception when undefined_function then null; end $$;

do $$ begin
  revoke execute on function public.create_order(
    text,text,text,text,numeric,numeric,text,jsonb
  ) from anon,authenticated;
exception when undefined_function then null; end $$;
