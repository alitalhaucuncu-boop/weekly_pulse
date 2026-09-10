import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/constants.dart';
import 'weekly_planner_screen.dart';

class AuthScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onThemeToggle;

  const AuthScreen({
    super.key,
    required this.isDark,
    required this.onThemeToggle,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLogin = true;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showForgotPasswordDialog() {
    final resetEmailController =
        TextEditingController(text: _emailController.text.trim());
    String? resetError;
    bool isResetSending = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Şifremi Unuttum 🔑',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Kayıtlı e-posta adresinizi girin. Size şifre sıfırlama bağlantısı göndereceğiz.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: resetEmailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: 'E-posta Adresi',
                      errorText: resetError,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isResetSending
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A55A2)),
                  onPressed: isResetSending
                      ? null
                      : () async {
                          final email = resetEmailController.text.trim();
                          if (email.isEmpty || !email.contains('@')) {
                            setStateDialog(() => resetError =
                                'Lütfen geçerli bir e-posta adresi girin.');
                            return;
                          }

                          setStateDialog(() {
                            isResetSending = true;
                            resetError = null;
                          });

                          try {
                            await supabase.auth.resetPasswordForEmail(email);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      '📩 Şifre sıfırlama bağlantısı e-postanıza gönderildi!'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          } catch (e) {
                            setStateDialog(() {
                              isResetSending = false;
                              resetError = 'Hata oluştu: $e';
                            });
                          }
                        },
                  child: isResetSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('Bağlantı Gönder',
                          style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleAuth() async {
    final email = _emailController.text.trim();
    // AUD-029: Şifre alanında trim yapılmaz, geçerli sınır boşlukları korunur
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Lütfen tüm alanları doldurun.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);

    try {
      if (isLogin) {
        final res = await supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );

        if (res.session != null && mounted) {
          nav.pushReplacement(
            MaterialPageRoute(
              builder: (_) => WeeklyPlannerScreen(
                isDark: widget.isDark,
                onThemeToggle: widget.onThemeToggle,
              ),
            ),
          );
        }
      } else {
        final res = await supabase.auth.signUp(
          email: email,
          password: password,
        );

        if (res.session == null && res.user != null) {
          if (mounted) {
            setState(() {
              _isLoading = false;
              isLogin = true;
            });
            scaffoldMessenger.showSnackBar(
              const SnackBar(
                content: Text(
                    '📩 Kayıt başarılı! Lütfen e-postanıza gelen doğrulama bağlantısına tıklayıp giriş yapın.'),
                duration: Duration(seconds: 5),
                backgroundColor: Colors.blueAccent,
              ),
            );
          }
          return;
        }

        if (res.session != null && mounted) {
          nav.pushReplacement(
            MaterialPageRoute(
              builder: (_) => WeeklyPlannerScreen(
                isDark: widget.isDark,
                onThemeToggle: widget.onThemeToggle,
              ),
            ),
          );
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Bağlantı hatası oluştu: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WeeklyPulse ⚡',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(
                widget.isDark ? Icons.light_mode : Icons.dark_mode_outlined),
            onPressed: widget.onThemeToggle,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(28.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isLogin ? 'Giriş Yap' : 'Kayıt Ol',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Hayat planını bozar, WeeklyPulse toparlar.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 20),
                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade100,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'E-posta',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Şifre',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (isLogin) ...[
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _showForgotPasswordDialog,
                          child: const Text('Şifremi Unuttum?',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4A55A2)),
                        onPressed: _isLoading ? null : _handleAuth,
                        child: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text(
                                isLogin ? 'Giriş Yap' : 'Hesap Oluştur',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          isLogin = !isLogin;
                          _errorMessage = null;
                        });
                      },
                      child: Text(
                        isLogin
                            ? 'Hesabınız yok mu? Kayıt Olun'
                            : 'Zaten hesabınız var mı? Giriş Yapın',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const Divider(height: 24),
                    TextButton.icon(
                      icon: const Icon(Icons.shield_outlined, size: 16),
                      label: const Text(
                          'Aydınlatma Metni & Gizlilik Politikası',
                          style: TextStyle(fontSize: 11)),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (dialogContext) {
                            return AlertDialog(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20)),
                              title: const Text('Gizlilik ve Güvenlik 🛡️',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              content: const SingleChildScrollView(
                                child: Text(
                                  'WeeklyPulse, haftalık görevlerinizi, akademik veya kurumsal planlarınızı cihazınız ve güvenli Supabase altyapısı arasında uçtan uca eşitler.\n\n'
                                  '• Verileriniz yalnızca size aittir ve üçüncü taraflarla paylaşılmaz.\n'
                                  '• Takvim entegrasyonu yalnızca görev saatlerinizi senkronize etmek için kullanılır.\n'
                                  '• Hesabınızı dilediğiniz zaman profil ekranından şifrenizle doğrulayarak tüm verilerinizle birlikte kalıcı olarak silebilirsiniz.',
                                  style: TextStyle(fontSize: 13, height: 1.4),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialogContext),
                                  child: const Text('Kapat'),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
