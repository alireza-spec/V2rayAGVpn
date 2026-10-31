import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The model menu's provider header is a DISABLED PopupMenuItem
// carrying its own IconButtons (collapse arrow, delete x), and
// each model row wraps its content in a GestureDetector for
// long-press delete. Both patterns must actually receive taps:
// a disabled item must not swallow its children's gestures,
// and a long-press must not also select the model.
void main() {
  testWidgets('IconButton inside a disabled PopupMenuItem still fires',
      (tester) async {
    var pressed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PopupMenuButton<String>(
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(children: [
                const Text('Groq'),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => pressed = true,
                ),
              ]),
            ),
            const PopupMenuItem(value: 'x', child: Text('model')),
          ],
          child: const Text('menu'),
        ),
      ),
    ));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(pressed, isTrue);
  });

  testWidgets('long-press on a menu model row fires without selecting it',
      (tester) async {
    var longPressed = false;
    String? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PopupMenuButton<String>(
          onSelected: (v) => selected = v,
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'm1',
              child: GestureDetector(
                onLongPress: () => longPressed = true,
                child: const Text('model-1'),
              ),
            ),
          ],
          child: const Text('menu'),
        ),
      ),
    ));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('model-1'));
    await tester.pump();
    expect(longPressed, isTrue);
    expect(selected, isNull);
  });
}
