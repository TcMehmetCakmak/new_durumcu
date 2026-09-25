-- DÜRÜMCÜ - İNDİRİM KODU + CANLI ADMIN + SİPARİŞ TOPLAM MIGRATION
-- Mevcut Supabase projesinde SQL Editor içinde BİR KEZ çalıştırın.

alter table public.notifications add column if not exists notification_type text not null default 'info';
alter table public.notifications add column if not exists discount_type text;
alter table public.notifications add column if not exists discount_value numeric(12,2);
alter table public.notifications add column if not exists coupon_code text;

alter table public.orders add column if not exists subtotal numeric(12,2);
alter table public.orders add column if not exists discount_amount numeric(12,2) not null default 0;
alter table public.orders add column if not exists coupon_code text;
update public.orders set subtotal=coalesce(subtotal,total) where subtotal is null;

alter table public.notifications drop constraint if exists notifications_notification_type_check;
alter table public.notifications add constraint notifications_notification_type_check check (notification_type in ('info','discount'));
alter table public.notifications drop constraint if exists notifications_discount_type_check;
alter table public.notifications add constraint notifications_discount_type_check check (discount_type is null or discount_type in ('percent','fixed'));
alter table public.notifications drop constraint if exists notifications_discount_value_check;
alter table public.notifications add constraint notifications_discount_value_check check (discount_value is null or discount_value > 0);
create unique index if not exists notifications_coupon_code_upper_uidx on public.notifications (upper(coupon_code)) where coupon_code is not null;

create or replace function public.prepare_notification_discount()
returns trigger language plpgsql set search_path=public as $$
begin
  new.notification_type := coalesce(new.notification_type,'info');
  if new.notification_type='discount' then
    if new.discount_type not in ('percent','fixed') then raise exception 'İndirim tipi percent veya fixed olmalıdır.'; end if;
    if new.discount_value is null or new.discount_value<=0 then raise exception 'İndirim değeri 0’dan büyük olmalıdır.'; end if;
    if new.discount_type='percent' and new.discount_value>100 then raise exception 'Yüzde indirim 100’den büyük olamaz.'; end if;
    if new.coupon_code is null or length(trim(new.coupon_code))=0 then
      new.coupon_code := 'DRM-' || upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text),1,8));
    else
      new.coupon_code := upper(trim(new.coupon_code));
    end if;
  else
    new.discount_type := null; new.discount_value := null; new.coupon_code := null;
  end if;
  return new;
end; $$;

drop trigger if exists notifications_prepare_discount on public.notifications;
create trigger notifications_prepare_discount before insert or update on public.notifications for each row execute function public.prepare_notification_discount();

-- Müşteri aktif bildirimleri en fazla 3 gün önceden görebilir.
drop policy if exists "Public read active notifications" on public.notifications;
create policy "Public read active notifications" on public.notifications for select to anon, authenticated
using (active=true and (start_date is null or start_date<=current_date+3) and (end_date is null or end_date>=current_date));

create or replace function public.validate_coupon(p_code text, p_subtotal numeric)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n public.notifications%rowtype; d numeric(12,2):=0; code text:=upper(trim(coalesce(p_code,'')));
begin
  if code='' then return jsonb_build_object('valid',false,'message','İndirim kodu boş.'); end if;
  select * into n from public.notifications
   where notification_type='discount' and active=true and upper(coupon_code)=code
     and (start_date is null or start_date<=current_date)
     and (end_date is null or end_date>=current_date)
   order by created_at desc limit 1;
  if not found then return jsonb_build_object('valid',false,'message','Kod geçersiz, kampanya henüz başlamadı veya süresi doldu.'); end if;
  if n.discount_type='percent' then d:=round(greatest(coalesce(p_subtotal,0),0)*least(n.discount_value,100)/100,2); else d:=least(greatest(coalesce(p_subtotal,0),0),n.discount_value); end if;
  return jsonb_build_object('valid',true,'code',n.coupon_code,'discount_type',n.discount_type,'discount_value',n.discount_value,'discount_amount',d,'title',n.title);
end; $$;
revoke all on function public.validate_coupon(text,numeric) from public;
grant execute on function public.validate_coupon(text,numeric) to anon,authenticated;

create or replace function public.create_order_with_coupon(
  p_name text, p_address text, p_payment text, p_note text default '',
  p_latitude numeric default null, p_longitude numeric default null,
  p_google_maps_url text default '', p_items jsonb default '[]'::jsonb,
  p_coupon_code text default ''
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_items jsonb; v_subtotal numeric(12,2); v_discount numeric(12,2):=0; v_total numeric(12,2); v_order_id bigint;
  v_requested integer; v_found integer; v_coupon public.notifications%rowtype; v_code text:=upper(trim(coalesce(p_coupon_code,'')));
begin
  if length(trim(coalesce(p_name,'')))=0 then raise exception 'Ad alanı zorunludur.'; end if;
  if length(trim(coalesce(p_address,'')))=0 then raise exception 'Adres alanı zorunludur.'; end if;
  if length(trim(coalesce(p_payment,'')))=0 then raise exception 'Ödeme yöntemi zorunludur.'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Geçersiz ürün listesi.'; end if;

  select count(distinct x->>'productId') into v_requested from jsonb_array_elements(p_items) x where coalesce((x->>'quantity')::integer,0)>0;
  select count(*) into v_found from (select distinct x->>'productId' product_id from jsonb_array_elements(p_items) x where coalesce((x->>'quantity')::integer,0)>0) r join public.products p on p.id=r.product_id and p.active=true;
  if v_requested=0 then raise exception 'Siparişte geçerli ürün yok.'; end if;
  if v_found<>v_requested then raise exception 'Siparişte bulunmayan veya pasif ürün var.'; end if;

  select jsonb_agg(jsonb_build_object('productId',p.id,'name',p.name,'icon',p.icon,'price',p.price,'quantity',q.quantity,'lineTotal',round(p.price*q.quantity,2)) order by p.created_at), round(sum(p.price*q.quantity),2)
    into v_items,v_subtotal
    from (select x->>'productId' product_id,(x->>'quantity')::integer quantity from jsonb_array_elements(p_items) x where coalesce((x->>'quantity')::integer,0)>0) q
    join public.products p on p.id=q.product_id and p.active=true;

  if v_code<>'' then
    select * into v_coupon from public.notifications where notification_type='discount' and active=true and upper(coupon_code)=v_code
      and (start_date is null or start_date<=current_date) and (end_date is null or end_date>=current_date) order by created_at desc limit 1;
    if not found then raise exception 'İndirim kodu geçersiz, henüz aktif değil veya süresi dolmuş.'; end if;
    if v_coupon.discount_type='percent' then v_discount:=round(v_subtotal*least(v_coupon.discount_value,100)/100,2); else v_discount:=least(v_subtotal,v_coupon.discount_value); end if;
  end if;
  v_total:=greatest(v_subtotal-v_discount,0);

  insert into public.orders(name,address,payment,note,latitude,longitude,google_maps_url,items,subtotal,discount_amount,coupon_code,total,status)
  values(trim(p_name),trim(p_address),trim(p_payment),coalesce(p_note,''),p_latitude,p_longitude,coalesce(p_google_maps_url,''),v_items,v_subtotal,v_discount,nullif(v_code,''),v_total,'devam-ediyor') returning id into v_order_id;
  return jsonb_build_object('id',v_order_id,'subtotal',v_subtotal,'discount_amount',v_discount,'coupon_code',nullif(v_code,''),'total',v_total,'items',v_items,'status','devam-ediyor');
end; $$;
revoke all on function public.create_order_with_coupon(text,text,text,text,numeric,numeric,text,jsonb,text) from public;
grant execute on function public.create_order_with_coupon(text,text,text,text,numeric,numeric,text,jsonb,text) to anon,authenticated;

alter table public.orders replica identity full;
alter table public.products replica identity full;
alter table public.notifications replica identity full;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='orders') then alter publication supabase_realtime add table public.orders; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='products') then alter publication supabase_realtime add table public.products; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then alter publication supabase_realtime add table public.notifications; end if;
  end if;
end $$;

-- =========================================================
-- V2: BIRDEN FAZLA INDIRIM KODU
-- =========================================================
alter table public.orders add column if not exists coupon_codes text[] not null default '{}'::text[];
update public.orders
set coupon_codes = case
  when coalesce(trim(coupon_code),'') <> '' then array[upper(trim(coupon_code))]
  else '{}'::text[]
end
where coalesce(array_length(coupon_codes,1),0)=0;

create or replace function public.validate_coupons(p_codes text[], p_subtotal numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  raw_code text;
  code text;
  n public.notifications%rowtype;
  remaining numeric(12,2):=greatest(coalesce(p_subtotal,0),0);
  d numeric(12,2):=0;
  total_discount numeric(12,2):=0;
  normalized text[]:='{}'::text[];
  coupon_list jsonb:='[]'::jsonb;
begin
  if coalesce(array_length(p_codes,1),0)=0 then
    return jsonb_build_object('valid',true,'codes','[]'::jsonb,'coupons','[]'::jsonb,'discount_amount',0,'total',remaining);
  end if;

  foreach raw_code in array p_codes loop
    code:=upper(trim(coalesce(raw_code,'')));
    if code='' then continue; end if;
    if code=any(normalized) then
      return jsonb_build_object('valid',false,'message','Aynı indirim kodu birden fazla kez kullanılamaz.');
    end if;

    select * into n
    from public.notifications
    where notification_type='discount'
      and active=true
      and upper(coupon_code)=code
      and (start_date is null or start_date<=current_date)
      and (end_date is null or end_date>=current_date)
    order by created_at desc
    limit 1;

    if not found then
      return jsonb_build_object('valid',false,'message',code || ' kodu geçersiz, kampanya henüz başlamadı veya süresi doldu.');
    end if;

    if n.discount_type='percent' then
      d:=round(remaining*least(n.discount_value,100)/100,2);
    else
      d:=least(remaining,n.discount_value);
    end if;
    d:=greatest(least(d,remaining),0);
    remaining:=remaining-d;
    total_discount:=total_discount+d;
    normalized:=array_append(normalized,code);
    coupon_list:=coupon_list || jsonb_build_array(jsonb_build_object(
      'code',n.coupon_code,
      'title',n.title,
      'discount_type',n.discount_type,
      'discount_value',n.discount_value,
      'discount_amount',d
    ));
  end loop;

  return jsonb_build_object(
    'valid',true,
    'codes',to_jsonb(normalized),
    'coupons',coupon_list,
    'discount_amount',round(total_discount,2),
    'total',round(remaining,2)
  );
end;
$$;
revoke all on function public.validate_coupons(text[],numeric) from public;
grant execute on function public.validate_coupons(text[],numeric) to anon,authenticated;

create or replace function public.create_order_with_coupons(
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
  v_items jsonb;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2):=0;
  v_total numeric(12,2);
  v_order_id bigint;
  v_requested integer;
  v_found integer;
  v_validation jsonb;
  v_codes text[]:='{}'::text[];
begin
  if length(trim(coalesce(p_name,'')))=0 then raise exception 'Ad alanı zorunludur.'; end if;
  if length(trim(coalesce(p_address,'')))=0 then raise exception 'Adres alanı zorunludur.'; end if;
  if length(trim(coalesce(p_payment,'')))=0 then raise exception 'Ödeme yöntemi zorunludur.'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Geçersiz ürün listesi.'; end if;

  select count(distinct x->>'productId') into v_requested
  from jsonb_array_elements(p_items) x
  where coalesce((x->>'quantity')::integer,0)>0;

  select count(*) into v_found
  from (
    select distinct x->>'productId' product_id
    from jsonb_array_elements(p_items) x
    where coalesce((x->>'quantity')::integer,0)>0
  ) r
  join public.products p on p.id=r.product_id and p.active=true;

  if v_requested=0 then raise exception 'Siparişte geçerli ürün yok.'; end if;
  if v_found<>v_requested then raise exception 'Siparişte bulunmayan veya pasif ürün var.'; end if;

  select
    jsonb_agg(jsonb_build_object(
      'productId',p.id,'name',p.name,'icon',p.icon,'price',p.price,
      'quantity',q.quantity,'lineTotal',round(p.price*q.quantity,2)
    ) order by p.created_at),
    round(sum(p.price*q.quantity),2)
  into v_items,v_subtotal
  from (
    select x->>'productId' product_id,(x->>'quantity')::integer quantity
    from jsonb_array_elements(p_items) x
    where coalesce((x->>'quantity')::integer,0)>0
  ) q
  join public.products p on p.id=q.product_id and p.active=true;

  v_validation:=public.validate_coupons(coalesce(p_coupon_codes,'{}'::text[]),v_subtotal);
  if coalesce((v_validation->>'valid')::boolean,false)<>true then
    raise exception '%',coalesce(v_validation->>'message','İndirim kodlarından biri geçersiz.');
  end if;

  select coalesce(array_agg(value), '{}'::text[])
  into v_codes
  from jsonb_array_elements_text(coalesce(v_validation->'codes','[]'::jsonb));

  v_discount:=coalesce((v_validation->>'discount_amount')::numeric,0);
  v_total:=greatest(v_subtotal-v_discount,0);

  insert into public.orders(
    name,address,payment,note,latitude,longitude,google_maps_url,items,
    subtotal,discount_amount,coupon_code,coupon_codes,total,status
  ) values (
    trim(p_name),trim(p_address),trim(p_payment),coalesce(p_note,''),
    p_latitude,p_longitude,coalesce(p_google_maps_url,''),v_items,
    v_subtotal,v_discount,
    case when coalesce(array_length(v_codes,1),0)>0 then v_codes[1] else null end,
    v_codes,v_total,'devam-ediyor'
  ) returning id into v_order_id;

  return jsonb_build_object(
    'id',v_order_id,
    'subtotal',v_subtotal,
    'discount_amount',v_discount,
    'coupon_code',case when coalesce(array_length(v_codes,1),0)>0 then v_codes[1] else null end,
    'coupon_codes',to_jsonb(v_codes),
    'total',v_total,
    'items',v_items,
    'status','devam-ediyor'
  );
end;
$$;
revoke all on function public.create_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[]) from public;
grant execute on function public.create_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[]) to anon,authenticated;


-- =========================================================
-- V3: WHATSAPP / TELEFON KODU İLE SİPARİŞ DOĞRULAMA
-- =========================================================
create extension if not exists pgcrypto;

alter table public.orders add column if not exists phone_number text;
alter table public.orders add column if not exists verification_method text;
alter table public.orders add column if not exists whatsapp_code_hash text;
alter table public.orders add column if not exists whatsapp_code_expires_at timestamptz;
alter table public.orders add column if not exists verified_at timestamptz;
alter table public.orders add column if not exists verification_attempts integer not null default 0;

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('onay-bekliyor','devam-ediyor','tamamlandi','iptal-edildi'));

create table if not exists public.order_verifications (
  id uuid primary key default gen_random_uuid(),
  phone_number text not null,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.order_verifications enable row level security;
revoke all on public.order_verifications from anon, authenticated;

create or replace function public.begin_phone_whatsapp_verification(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_phone text:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
  v_code text:=lpad(((floor(random()*900000)+100000)::int)::text,6,'0');
  v_id uuid;
begin
  if v_phone !~ '^90[0-9]{10}$' then raise exception 'Geçerli telefon numarası girin.'; end if;
  insert into public.order_verifications(phone_number,code_hash,expires_at)
  values(v_phone,encode(digest(v_code,'sha256'),'hex'),now()+interval '10 minutes')
  returning id into v_id;
  return jsonb_build_object('challenge_id',v_id,'code',v_code,'expires_at',now()+interval '10 minutes');
end; $$;
revoke all on function public.begin_phone_whatsapp_verification(text) from public;
grant execute on function public.begin_phone_whatsapp_verification(text) to anon,authenticated;

create or replace function public.create_verified_order_with_coupons(
  p_name text,p_address text,p_payment text,p_note text default '',
  p_latitude numeric default null,p_longitude numeric default null,
  p_google_maps_url text default '',p_items jsonb default '[]'::jsonb,
  p_coupon_codes text[] default '{}'::text[],
  p_phone text default '',p_challenge_id uuid default null,p_code text default ''
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.order_verifications%rowtype;
  r jsonb;
  v_id bigint;
begin
  select * into v from public.order_verifications where id=p_challenge_id for update;
  if not found then raise exception 'Doğrulama kaydı bulunamadı.'; end if;
  if v.used_at is not null then raise exception 'Bu doğrulama kodu daha önce kullanıldı.'; end if;
  if v.expires_at<now() then raise exception 'Doğrulama kodunun süresi doldu.'; end if;
  if v.attempts>=5 then raise exception 'Çok fazla hatalı deneme yapıldı.'; end if;
  if v.phone_number<>regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') then raise exception 'Telefon numarası eşleşmiyor.'; end if;
  if v.code_hash<>encode(digest(trim(coalesce(p_code,'')),'sha256'),'hex') then
    update public.order_verifications set attempts=attempts+1 where id=v.id;
    raise exception 'Güvenlik kodu hatalı.';
  end if;

  r:=public.create_order_with_coupons(p_name,p_address,p_payment,p_note,p_latitude,p_longitude,p_google_maps_url,p_items,p_coupon_codes);
  v_id:=(r->>'id')::bigint;
  update public.orders
     set phone_number=v.phone_number,verification_method='phone-whatsapp',verified_at=now(),status='devam-ediyor'
   where id=v_id;
  update public.order_verifications set used_at=now() where id=v.id;
  return r || jsonb_build_object('phone_number',v.phone_number,'verification_method','phone-whatsapp','status','devam-ediyor');
end; $$;
revoke all on function public.create_verified_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[],text,uuid,text) from public;
grant execute on function public.create_verified_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[],text,uuid,text) to anon,authenticated;

create or replace function public.create_pending_whatsapp_order_with_coupons(
  p_name text,p_address text,p_payment text,p_note text default '',
  p_latitude numeric default null,p_longitude numeric default null,
  p_google_maps_url text default '',p_items jsonb default '[]'::jsonb,
  p_coupon_codes text[] default '{}'::text[]
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r jsonb;
  v_id bigint;
  v_code text:=lpad(((floor(random()*900000)+100000)::int)::text,6,'0');
begin
  r:=public.create_order_with_coupons(p_name,p_address,p_payment,p_note,p_latitude,p_longitude,p_google_maps_url,p_items,p_coupon_codes);
  v_id:=(r->>'id')::bigint;
  update public.orders
     set status='onay-bekliyor',verification_method='whatsapp-business',
         whatsapp_code_hash=encode(digest(v_code,'sha256'),'hex'),
         whatsapp_code_expires_at=now()+interval '30 minutes',verification_attempts=0
   where id=v_id;
  return r || jsonb_build_object('status','onay-bekliyor','security_code',v_code);
end; $$;
revoke all on function public.create_pending_whatsapp_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[]) from public;
grant execute on function public.create_pending_whatsapp_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[]) to anon,authenticated;

create or replace function public.verify_whatsapp_order(p_order_id bigint,p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare o public.orders%rowtype;
begin
  if not public.is_admin() then raise exception 'Yetkisiz işlem.'; end if;
  select * into o from public.orders where id=p_order_id for update;
  if not found then raise exception 'Sipariş bulunamadı.'; end if;
  if o.status<>'onay-bekliyor' then raise exception 'Sipariş onay beklemiyor.'; end if;
  if o.whatsapp_code_expires_at is null or o.whatsapp_code_expires_at<now() then raise exception 'Güvenlik kodunun süresi doldu.'; end if;
  if o.verification_attempts>=5 then raise exception 'Çok fazla hatalı deneme yapıldı.'; end if;
  if o.whatsapp_code_hash<>encode(digest(trim(coalesce(p_code,'')),'sha256'),'hex') then
    update public.orders set verification_attempts=verification_attempts+1 where id=p_order_id;
    raise exception 'Güvenlik kodu hatalı.';
  end if;
  update public.orders set status='devam-ediyor',verified_at=now(),whatsapp_code_hash=null,whatsapp_code_expires_at=null where id=p_order_id;
  return jsonb_build_object('id',p_order_id,'status','devam-ediyor','verified',true);
end; $$;
revoke all on function public.verify_whatsapp_order(bigint,text) from public;
grant execute on function public.verify_whatsapp_order(bigint,text) to authenticated;

-- Eski doğrudan sipariş RPC'leri doğrulama akışını atlamasın.
do $$ begin
  revoke execute on function public.create_order_with_coupons(text,text,text,text,numeric,numeric,text,jsonb,text[]) from anon,authenticated;
exception when undefined_function then null; end $$;
do $$ begin
  revoke execute on function public.create_order_with_coupon(text,text,text,text,numeric,numeric,text,jsonb,text) from anon,authenticated;
exception when undefined_function then null; end $$;
do $$ begin
  revoke execute on function public.create_order(text,text,text,text,numeric,numeric,text,jsonb) from anon,authenticated;
exception when undefined_function then null; end $$;
