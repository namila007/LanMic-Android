enum Quality { good, ok, slow }

/// Unknown delay gives no word; unknown loss counts as 0.
Quality? qualityOf({required int? delayMs, int? lostPermille}) {
  if (delayMs == null) return null;
  final lost = lostPermille ?? 0;
  if (delayMs >= 200 || lost >= 50) return Quality.slow;
  if (delayMs < 100 && lost < 10) return Quality.good;
  return Quality.ok;
}
