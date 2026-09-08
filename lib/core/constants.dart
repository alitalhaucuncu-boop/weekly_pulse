import 'package:supabase_flutter/supabase_flutter.dart';

const String supabaseUrl = 'https://bfrdblsvzdygvnjsmpwi.supabase.co';
const String supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJmcmRibHN2emR5Z3ZuanNtcHdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2MDQ2OTgsImV4cCI6MjEwMjE4MDY5OH0.M7uccvhaPUxPQ9wFuvl1nNDViH5lLjfynm55wt_xL84';

final supabase = Supabase.instance.client;

const List<String> weekDays = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];

const List<String> fullWeekDays = [
  'Pazartesi',
  'Salı',
  'Çarşamba',
  'Perşembe',
  'Cuma',
  'Cumartesi',
  'Pazar'
];

const List<String> monthNames = [
  'Ocak',
  'Şubat',
  'Mart',
  'Nisan',
  'Mayıs',
  'Haziran',
  'Temmuz',
  'Ağustos',
  'Eylül',
  'Ekim',
  'Kasım',
  'Aralık'
];
