DÜRÜMCÜ - GITHUB PAGES + SUPABASE + PWA

KURULUM / GÜNCELLEME
1. Proje dosyalarını GitHub Pages repository köküne yükleyin.
2. Mevcut Supabase kurulumunuz varsa sadece notification-live-fix.sql dosyasını SQL Editor'da bir kez çalıştırın.
3. İlk kurulum yapıyorsanız schema.sql dosyasını kullanabilirsiniz.
4. supabase-config.js içindeki Project URL ve publishable/anon key bilgilerini kontrol edin.
5. service_role / secret key frontend'e koymayın.

BİLDİRİM KURALI
- active=true olmalı.
- Süresi geçmiş bildirim gösterilmez.
- start_date boşsa hemen görünür.
- start_date bugün veya en fazla 3 gün sonrası ise görünür.
- 4+ gün sonra başlayacak bildirim henüz müşteriye gösterilmez.
- Zaman ilerleyip 3 günlük pencereye girdiğinde açık sayfa otomatik senkronizasyon ile bildirimi getirir.
- Admin ekleme/güncelleme/silme işlemleri Supabase Realtime ile açık müşteri sayfasına refresh gerektirmeden yansır.
- Realtime kısa süreli koparsa 5 saniyelik otomatik senkronizasyon yedek olarak çalışır.

PWA
- index.html ve admin.html network-first çalışır; eski cache ana sayfayı kilitlemez.
- manifest.json + service-worker.js + icon-192.png + icon-512.png dahildir.
