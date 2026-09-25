DÜRÜMCÜ - GITHUB PAGES + SUPABASE

1. Supabase'te proje oluştur.
2. supabase/schema.sql dosyasının tamamını Supabase > SQL Editor'da çalıştır.
3. Authentication > Users > Add user ile işletme hesabı oluştur.
4. Kullanıcının UUID'sini al.
5. schema.sql içindeki profiles INSERT satırını gerçek UUID ile çalıştır.
6. Project Settings > API'den Project URL ve Publishable key (eski projelerde anon key) al.
7. public/supabase-config.js dosyasına bunları yaz.
8. public klasörünü GitHub Pages repository köküne koy.
9. GitHub Pages'i Settings > Pages'ten aç.

Müşteri: index.html
Admin: admin.html

Ürünler artık index.html'e yazılmaz. Admin paneli Supabase products tablosunu değiştirir.
Müşteri sayfası products tablosundaki güncel aktif ürünleri okur.

Sipariş fiyatı browser'dan alınmaz; create_order PostgreSQL fonksiyonu mevcut ürün
fiyatlarından tekrar hesaplar ve orders tablosuna kaydeder.

service_role/secret key'i frontend'e koymayın.

YENİ: YORUM + BİLDİRİM + PWA
- Güncel schema.sql dosyasını Supabase SQL Editor'da tekrar çalıştırın. reviews ve notifications tabloları/policy'leri eklenir.
- Admin panelinde "Bildirimler" sekmesinden eklenen aktif bildirimler tüm müşterilerde görünür.
- Müşteri yorumları artık localStorage yerine Supabase reviews tablosunda tutulur; tüm cihazlarda ortaktır.
- PWA için manifest.json, service-worker.js, icon-192.png ve icon-512.png dosyalarını da repository köküne koyun.
- PWA kurulumu için site HTTPS üzerinden açılmalıdır (GitHub Pages HTTPS sağlar).
