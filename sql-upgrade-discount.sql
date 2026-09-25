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
