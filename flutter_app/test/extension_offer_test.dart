import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:serene_app/src/extension_offer.dart';
import 'package:serene_app/src/strings.dart';

/// Pencereyi gercek bir Navigator uzerinde acar; kapanma davranisi boylece
/// dugme ve zamanlayici uzerinden gercekten olculur.
Future<ValueNotifier<bool>> _openOffer(WidgetTester tester) async {
  final up = ValueNotifier(false);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ExtensionOfferDialog(
                  browserUp: up,
                  folder: Directory(r'C:\serene-test\extension'),
                ),
              ),
              child: const Text('ac'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ac'));
  await tester.pumpAndSettle();
  return up;
}

void main() {
  testWidgets('tanitim penceresi "Simdi degil" ile kapanir', (tester) async {
    await _openOffer(tester);
    expect(find.text(T.extensionOfferTitle), findsOneWidget);
    expect(find.text(T.extensionOfferBadge), findsOneWidget);

    await tester.tap(find.text(T.extensionOfferLater));
    await tester.pumpAndSettle();
    expect(find.text(T.extensionOfferTitle), findsNothing);
  });

  testWidgets('eklenti baglaninca pencere "Baglandi" gosterip kendini kapatir', (
    tester,
  ) async {
    final up = await _openOffer(tester);

    up.value = true;
    await tester.pump();
    expect(find.text(T.extensionOfferConnected), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.text(T.extensionOfferTitle), findsNothing);
  });
}
