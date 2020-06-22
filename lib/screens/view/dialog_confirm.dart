import 'package:flutter/material.dart';
import 'package:nmobile/l10n/localization_intl.dart';

class SimpleConfirm {
  final BuildContext context;
  final String title;
  final String content;
  final String buttonText;
  final ValueChanged<bool> callback;

  SimpleConfirm({@required this.context, this.title, @required this.content, this.callback, this.buttonText});

  Future<void> show() {
    String title = this.title;
    String buttonText = this.buttonText;
    if (title == null || title.isEmpty) title = NMobileLocalizations.of(context).tip;
    if (buttonText == null || buttonText.isEmpty) buttonText = NMobileLocalizations.of(context).ok;
    return showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(title, style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w500)),
            content: Text(content, style: TextStyle(color: Colors.grey[500], fontSize: 15)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            actions: <Widget>[
              FlatButton(
                child: Text(NMobileLocalizations.of(context).cancel.toUpperCase(), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                onPressed: () {
                  Navigator.of(context).pop();
                  if (callback != null) callback(false);
                },
              ),
              FlatButton(
                child: Text(buttonText.toUpperCase(), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                onPressed: () {
                  Navigator.of(context).pop();
                  if (callback != null) callback(true);
                },
              )
            ],
          );
        });
  }
}
