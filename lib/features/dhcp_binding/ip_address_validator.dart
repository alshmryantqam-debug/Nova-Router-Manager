import 'dart:io';

/// Validates an IPv4 or IPv6 literal, optionally with a CIDR prefix.
bool isValidIpAddressOrCidr(String value) {
  final input = value.trim();
  if (input.isEmpty) return false;

  final parts = input.split('/');
  if (parts.length > 2) return false;

  final address = InternetAddress.tryParse(parts.first);
  if (address == null) return false;
  if (parts.length == 1) return true;

  final prefixText = parts[1];
  if (!RegExp(r'^\d{1,3}$').hasMatch(prefixText)) return false;
  final prefix = int.tryParse(prefixText);
  if (prefix == null) return false;

  final maximumPrefix =
      address.type == InternetAddressType.IPv4 ? 32 : 128;
  return prefix <= maximumPrefix;
}
