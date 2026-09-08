import 'package:flutter/material.dart';
import '../../core/constants.dart';
import 'weekly_planner_screen.dart';

class AuthScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDark;

  const AuthScreen({
    super.key,
    required this.onThemeToggle,
    required this.isDark,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLogin = true;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  DateTime? _selectedBirthDate;
  bool _isLoading = false;

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen tüm alanları doldurun.')),
      );
      return;
    }

    if (!isLogin && _selectedBirthDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen doğum tarihinizi seçin.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (isLogin) {
        final res = await supabase.auth
            .signInWithPassword(email: email, password: password);
        if (res.session != null && mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => WeeklyPlannerScreen(
                onThemeToggle: widget.onThemeToggle,
                isDark: widget.isDark,
              ),
            ),
          );
        }
      } else {
        final res =
            await supabase.auth.signUp(email: email, password: password);

        if (res.session != null && _selectedBirthDate != null) {
          try {
            await supabase.rpc('complete_user_profile', params: {
              'p_birth_date': _selectedBirthDate!.toIso8601String(),
            });
          } catch (e) {
            debugPrint("Profil Tamamlama Hatası: $e");
          }

          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => WeeklyPlannerScreen(
                  onThemeToggle: widget.onThemeToggle,
                  isDark: widget.isDark,
                ),
              ),
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Kayıt başarılı! Lütfen e-posta adresinize gelen doğrulama bağlantısına tıklayın.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 5),
            ),
          );
          setState(() => isLogin = true);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'İşlem sırasında bir hata oluştu. Lütfen bilgilerinizi kontrol edin.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isLogin ? 'Giriş Yap' : 'Kayıt Ol'),
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.calendar_month,
                  size: 72, color: Color(0xFF7895CB)),
              const SizedBox(height: 16),
              const Text(
                'WeeklyPulse',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'E-posta',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Şifre',
                  border: OutlineInputBorder(),
                ),
              ),
              if (!isLogin) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cake_outlined),
                  label: Text(
                    _selectedBirthDate == null
                        ? 'Doğum Tarihi Seç'
                        : 'Doğum Tarihi: ${_selectedBirthDate!.day}/${_selectedBirthDate!.month}/${_selectedBirthDate!.year}',
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime(2000),
                      firstDate: DateTime(1940),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setState(() => _selectedBirthDate = picked);
                    }
                  },
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7895CB)),
                  onPressed: _isLoading ? null : _submit,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(isLogin ? 'Giriş Yap' : 'Kayıt Ol',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => setState(() => isLogin = !isLogin),
                child: Text(isLogin
                    ? 'Hesabın yok mu? Kayıt Ol'
                    : 'Zaten hesabın var mı? Giriş Yap'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
