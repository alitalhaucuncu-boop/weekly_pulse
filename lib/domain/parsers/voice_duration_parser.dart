import '../models/voice_models.dart';

class VoiceDurationParser {
  static const Map<String, int> numberMap = {
    'sıfır': 0,
    'bir': 1,
    'iki': 2,
    'üç': 3,
    'dört': 4,
    'beş': 5,
    'altı': 6,
    'yedi': 7,
    'sekiz': 8,
    'dokuz': 9,
    'on': 10,
    'on bir': 11,
    'on iki': 12,
    'on üç': 13,
    'on dört': 14,
    'on beş': 15,
    'on altı': 16,
    'on yedi': 17,
    'on sekiz': 18,
    'on dokuz': 19,
    'yirmi': 20,
    'yirmi beş': 25,
    'otuz': 30,
    'kırk': 40,
    'kırk beş': 45,
    'elli': 50,
    'altmış': 60,
    'yetmiş': 70,
    'seksen': 80,
    'doksan': 90,
  };

  static int? _parseWordOrDigits(String text) {
    text = text.trim().toLowerCase();
    final asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    return numberMap[text];
  }

  static DurationParseResult parse(String input) {
    String workingText = input.toLowerCase();
    int totalMinutes = 0;
    bool foundAnyDuration = false;

    final decimalHourRegex = RegExp(r'\b(\d+)(?:[\.,](\d+))\s*saat(lik)?\b');
    final decMatch = decimalHourRegex.firstMatch(workingText);
    if (decMatch != null) {
      foundAnyDuration = true;
      double whole = double.tryParse(decMatch.group(1)!) ?? 1.0;
      double frac = double.tryParse("0.${decMatch.group(2)!}") ?? 0.5;
      totalMinutes += ((whole + frac) * 60).round();
    }

    if (!foundAnyDuration) {
      final hourRegex = RegExp(
        r'\b(\d+|on iki|on bir|on|dokuz|sekiz|yedi|altı|beş|dört|üç|iki|bir)'
        r'(?:\s+buçuk)?\s*saat(lik)?\b',
      );
      final hourMatch = hourRegex.firstMatch(workingText);
      if (hourMatch != null) {
        foundAnyDuration = true;
        final rawNum = hourMatch.group(1)!;
        final hasHalf = hourMatch.group(0)!.contains('buçuk');
        final parsedH = _parseWordOrDigits(rawNum) ?? 1;
        totalMinutes += (parsedH * 60) + (hasHalf ? 30 : 0);
      }
    }

    final halfHourRegex = RegExp(r'\byarım\s*saat(lik)?\b');
    if (!foundAnyDuration && halfHourRegex.hasMatch(workingText)) {
      foundAnyDuration = true;
      totalMinutes += 30;
    }

    final minRegex = RegExp(
      r'\b(\d+|doksan|altmış|elli|kırk beş|kırk|otuz|yirmi beş|yirmi|on beş|on|beş)\s*dakika(lık)?\b',
    );
    final minMatch = minRegex.firstMatch(workingText);
    if (minMatch != null) {
      foundAnyDuration = true;
      final rawMin = minMatch.group(1)!;
      final parsedM = _parseWordOrDigits(rawMin) ?? 30;
      totalMinutes += parsedM;
    }

    String cleaned = workingText;
    cleaned = cleaned
        .replaceAll(decimalHourRegex, '')
        .replaceAll(
            RegExp(
                r'\b(\d+|on iki|on bir|on|dokuz|sekiz|yedi|altı|beş|dört|üç|iki|bir)(?:\s+buçuk)?\s*saat(lik)?\b'),
            '')
        .replaceAll(halfHourRegex, '')
        .replaceAll(minRegex, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (!foundAnyDuration) {
      return DurationParseResult(
        durationMinutes: 60,
        cleanedText: cleaned,
      );
    }

    String? error;
    if (totalMinutes < 15) {
      error =
          "Belirtilen süre ($totalMinutes dk) minimum planlama süresi olan 15 dakikadan az.";
    } else if (totalMinutes > 480) {
      error = "Görev süresi 8 saati (${totalMinutes ~/ 60} saat) aşamaz.";
    }

    int normalized = totalMinutes.clamp(15, 480).toInt();

    return DurationParseResult(
      durationMinutes: normalized,
      cleanedText: cleaned,
      validationError: error,
    );
  }
}
