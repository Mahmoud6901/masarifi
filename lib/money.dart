/// Currency precision agreed for the app; amounts are never converted.
int currencyDecimals(String currency) =>
    const {'KWD', 'BHD', 'OMR'}.contains(currency.toUpperCase()) ? 3 : 2;

int currencyScale(String currency) =>
    currencyDecimals(currency) == 3 ? 1000 : 100;

/// numeric(14,3) has eleven integer digits. Validate before writing or rounding.
bool isValidMoney(double amount, String currency) =>
    amount.isFinite &&
    amount >= 0 &&
    amount < 100000000000 &&
    double.parse(amount.toStringAsFixed(currencyDecimals(currency))) == amount;

int moneyUnits(double amount, String currency) =>
    (amount * currencyScale(currency)).round();
double moneyFromUnits(int units, String currency) =>
    units / currencyScale(currency);
int maxMoneyUnits(String currency) =>
    100000000000 * currencyScale(currency) - 1;
