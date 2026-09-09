import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../widgets/legal_modal.dart';
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
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Lütfen e-posta ve şifrenizi girin.');
      return;
    }

    if (password.length < 6) {
      setState(() => _errorMessage = 'Şifre en az 6 karakter olmalıdır.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_isSignUp) {
        final res = await supabase.auth.signUp(
          email: email,
          password: password,
        );
        if (res.user == null) {
          throw Exception('Kayıt oluşturulamadı.');
        }
      } else {
        final res = await supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );
        if (res.user == null) {
          throw Exception('Giriş başarısız.');
        }
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => WeeklyPlannerScreen(
              isDark: widget.isDark,
              onThemeToggle: widget.onThemeToggle,
            ),
          ),
        );
      }
    } catch (e) {
      String msg = 'Giriş yapılamadı. Bilgilerinizi kontrol edin.';
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('user already registered')) {
        msg = 'Bu e-posta ile zaten bir hesap var. Giriş yapmayı deneyin.';
      } else if (errStr.contains('invalid login credentials')) {
        msg = 'E-posta veya şifre hatalı.';
      } else if (errStr.contains('network') || errStr.contains('socket')) {
        msg = 'İnternet bağlantınızı kontrol edin.';
      }
      if (mounted) {
        setState(() => _errorMessage = msg);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showForgotPasswordDialog() {
    final resetEmailController =
        TextEditingController(text: _emailController.text.trim());
    bool isSending = false;
    String? dialogError;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Şifremi Unuttum 🔑',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Şifre sıfırlama bağlantısı almak için hesabınıza kayıtlı e-posta adresinizi yazın.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: resetEmailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'E-Posta Adresi',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: 8),
                    Text(dialogError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Vazgeç'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A55A2)),
                  onPressed: isSending
                      ? null
                      : () async {
                          final email = resetEmailController.text.trim();
                          if (email.isEmpty || !email.contains('@')) {
                            setDialogState(() => dialogError =
                                'Geçerli bir e-posta adresi girin.');
                            return;
                          }

                          setDialogState(() {
                            isSending = true;
                            dialogError = null;
                          });

                          try {
                            await supabase.auth.resetPasswordForEmail(email);
                            if (!dialogCtx.mounted) return;
                            Navigator.pop(dialogCtx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Şifre sıfırlama e-postası gönderildi. Kutunuzu kontrol edin.'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          } catch (e) {
                            setDialogState(() {
                              isSending = false;
                              dialogError = 'E-posta gönderilemedi: $e';
                            });
                          }
                        },
                  child: isSending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('Gönder',
                          style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF4A55A2);

    return Scaffold(
      appBar: AppBar(
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
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.calendar_month_rounded,
                    size: 48, color: primaryColor),
              ),
              const SizedBox(height: 16),
              const Text(
                'WeeklyPulse',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Hayat planını bozar, WeeklyPulse toparlar.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 28),
              if (_errorMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'E-Posta',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
              if (!_isSignUp) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _showForgotPasswordDialog,
                    child: const Text('Şifremi Unuttum',
                        style: TextStyle(fontSize: 12, color: primaryColor)),
                  ),
                ),
              ] else
                const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _isLoading ? null : _submit,
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _isSignUp ? 'Hesap Oluştur' : 'Giriş Yap',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isSignUp = !_isSignUp;
                    _errorMessage = null;
                  });
                },
                child: Text(
                  _isSignUp
                      ? 'Zaten hesabınız var mı? Giriş yapın'
                      : 'Hesabınız yok mu? Hemen kaydolun',
                  style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => LegalModal.showPrivacyPolicy(context),
                child: const Text(
                  'Kullanım Şartları ve Gizlilik Politikası (KVKK)',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
