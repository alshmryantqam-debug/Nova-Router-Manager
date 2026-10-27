import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'hotspot_service.dart';

/// Creates eight voucher cards per page and provides native print/share actions.
class VoucherPdfService {
  const VoucherPdfService();

  Future<Uint8List> buildPdfBytes({
    required List<HotspotVoucher> vouchers,
    required String networkName,
    String portalUrl = '',
    PdfPageFormat pageFormat = PdfPageFormat.a4,
  }) async {
    if (vouchers.isEmpty) {
      throw ArgumentError.value(vouchers, 'vouchers', 'لا توجد كروت لتصديرها.');
    }

    final document = pw.Document(
      title: 'HotSpot Vouchers - ${networkName}',
      author: 'Nova Router Manager',
      subject: 'HotSpot voucher cards',
    );

    const cardsPerPage = 8;
    for (var start = 0; start < vouchers.length; start += cardsPerPage) {
      final end = (start + cardsPerPage) < vouchers.length ? start + cardsPerPage : vouchers.length;
      final pageVouchers = vouchers.sublist(start, end);
      final rows = <pw.TableRow>[];

      for (var index = 0; index < pageVouchers.length; index += 2) {
        rows.add(
          pw.TableRow(
            verticalAlignment: pw.TableCellVerticalAlignment.middle,
            children: <pw.Widget>[
              _voucherCard(pageVouchers[index], networkName, portalUrl),
              index + 1 < pageVouchers.length
                  ? _voucherCard(pageVouchers[index + 1], networkName, portalUrl)
                  : pw.Container(height: 126),
            ],
          ),
        );
      }

      document.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.fromLTRB(22, 22, 22, 22),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: <pw.Widget>[
                  pw.Container(
                    width: 34,
                    height: 34,
                    decoration: pw.BoxDecoration(
                      color: PdfColors.deepPurple,
                      borderRadius: pw.BorderRadius.circular(8),
                    ),
                    child: pw.Center(
                      child: pw.Text(
                        'N',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 19,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 10),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: <pw.Widget>[
                        pw.Text(
                          networkName.trim().isEmpty ? 'NOVA HOTSPOT' : networkName.trim(),
                          maxLines: 1,
                          style: pw.TextStyle(
                            fontSize: 17,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.grey900,
                          ),
                        ),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          'HOTSPOT VOUCHERS  |  ${start + 1}-${end} of ${vouchers.length}',
                          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                        ),
                      ],
                    ),
                  ),
                  pw.Text(
                    'NOVA ROUTER MANAGER',
                    style: pw.TextStyle(
                      color: PdfColors.deepPurple,
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 13),
              pw.Container(height: 1, color: PdfColors.grey300),
              pw.SizedBox(height: 9),
              pw.Table(
                columnWidths: const <int, pw.TableColumnWidth>{
                  0: pw.FlexColumnWidth(1),
                  1: pw.FlexColumnWidth(1),
                },
                defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
                children: rows,
              ),
              pw.Spacer(),
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  'Keep this card private. Each code grants access according to its profile.',
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return document.save();
  }

  pw.Widget _voucherCard(HotspotVoucher voucher, String networkName, String portalUrl) {
    final quota = voucher.limitBytesTotal > 0 ? _formatBytes(voucher.limitBytesTotal) : 'No data cap';
    final timeCap = voucher.limitUptime.trim().isEmpty ? 'Profile expiry' : voucher.limitUptime.trim();
    final validity = voucher.validityLabel.trim().isNotEmpty ? voucher.validityLabel.trim() : timeCap;

    return pw.Container(
      height: 126,
      margin: const pw.EdgeInsets.all(4),
      padding: const pw.EdgeInsets.all(9),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
        borderRadius: pw.BorderRadius.circular(9),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: <pw.Widget>[
                pw.Text(
                  networkName.trim().isEmpty ? 'NOVA HOTSPOT' : networkName.trim(),
                  maxLines: 1,
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.deepPurple800),
                ),
                pw.Text('LOGIN CODE', style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600)),
                pw.Text(
                  voucher.username,
                  maxLines: 1,
                  style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.grey900),
                ),
                if (voucher.password.isNotEmpty)
                  pw.Text('PASS: ${voucher.password}', maxLines: 1, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800)),
                pw.Text('PLAN: ${voucher.profile}', maxLines: 1, style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey800)),
                pw.Text('VALID: $validity', maxLines: 1, style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey800)),
                pw.Text(
                  'DATA: $quota${voucher.price.trim().isEmpty ? '' : '  |  PRICE: ${voucher.price.trim()}'}',
                  maxLines: 1,
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey800),
                ),
                pw.Text('BATCH: ${voucher.batchId}', maxLines: 1, style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey600)),
              ],
            ),
          ),
          pw.SizedBox(width: 7),
          pw.Container(
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: voucher.qrPayload(portalUrl: portalUrl),
              width: 66,
              height: 66,
              drawText: false,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> shareVouchers({
    required List<HotspotVoucher> vouchers,
    required String networkName,
    String portalUrl = '',
  }) async {
    final bytes = await buildPdfBytes(vouchers: vouchers, networkName: networkName, portalUrl: portalUrl);
    final baseName = networkName.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final filename = 'nova-hotspot-' +
        (baseName.isEmpty ? 'vouchers' : baseName) +
        '-' +
        vouchers.first.batchId +
        '.pdf';
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  Future<bool> printVouchers({
    required List<HotspotVoucher> vouchers,
    required String networkName,
    String portalUrl = '',
  }) {
    if (vouchers.isEmpty) throw ArgumentError.value(vouchers, 'vouchers', 'لا توجد كروت للطباعة.');
    return Printing.layoutPdf(
      name: 'NOVA-HotSpot-' + vouchers.first.batchId,
      onLayout: (format) => buildPdfBytes(
        vouchers: vouchers,
        networkName: networkName,
        portalUrl: portalUrl,
        pageFormat: format,
      ),
    );
  }

  static String _formatBytes(int bytes) {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return value.toStringAsFixed(unit == 0 ? 0 : 1) + ' ' + units[unit];
  }
}
