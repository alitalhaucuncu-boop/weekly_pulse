import 'package:flutter/material.dart';

class LegalModal {
  static void showPrivacyPolicy(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          height: MediaQuery.of(ctx).size.height * 0.8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Gizlilik Politikası & KVKK',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(),
              const Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    '''WeeklyPulse olarak kişisel verilerinizin güvenliğine büyük önem veriyoruz.

1. Toplanan Veriler:
• Hesap Bilgileri: Kayıt esnasında sağlanan e-posta adresi ve şifrelenmiş kimlik bilgileri.
• Görev ve Planlama Verileri: Eklediğiniz görevler, teslim tarihleri, süreler, öncelikler ve tamamlanma durumları.
• Takvim ve Bildirim Bilgileri: Cihazınızda yerel olarak kurulan bildirim ID'leri ve tercih ettiğiniz takvim etkinlik referansları.

2. Verilerin İşlenme Amacı:
Verileriniz yalnızca planlarınızı cihazlar arasında senkronize etmek, zamanında hatırlatıcı bildirimler iletmek ve haftalık iş yükü analizinizi gerçekleştirmek amacıyla işlenir.

3. Üçüncü Taraflarla Paylaşım:
Kişisel verileriniz, görevleriniz veya takvim etkinlikleriniz asla reklam şirketleri veya üçüncü taraf veri sağlayıcıları ile satılmaz veya paylaşılmaz.

4. Veri Saklama ve Hesap Silme:
Kullanıcılar diledikleri zaman Profil menüsü altından "Hesabımı Kalıcı Olarak Sil" seçeneğini kullanarak tüm görevlerini, kotalarını ve hesap geçmişlerini veritabanından kalıcı ve geri alınamaz şekilde silebilirler.

İletişim: support@weeklypulse.app''',
                    style: TextStyle(
                        fontSize: 13, height: 1.5, color: Colors.blueGrey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7895CB)),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Kapat',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
