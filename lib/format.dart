import 'package:intl/intl.dart';

import 'money.dart';

String money(double amount, String currency) =>
    '${NumberFormat('#,##0.${'0' * currencyDecimals(currency)}').format(amount)} $currency';

String shortDate(DateTime d) => DateFormat('d MMM, HH:mm').format(d);

String dayMonth(DateTime d) => DateFormat('d MMM yyyy').format(d);
