import 'package:flutter/material.dart';
import 'package:nmobile/blocs/account_depends_bloc.dart';
import 'package:nmobile/blocs/chat/chat_bloc.dart';
import 'package:nmobile/blocs/chat/chat_event.dart';
import 'package:nmobile/components/label.dart';
import 'package:nmobile/consts/theme.dart';
import 'package:nmobile/l10n/localization_intl.dart';
import 'package:nmobile/schemas/contact.dart';
import 'package:nmobile/schemas/message.dart';
import 'package:nmobile/schemas/options.dart';

class BurnViewUtil {
  static List<Duration> burnValueArray = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(days: 1),
  ];

  static String getStringFromSeconds(context, seconds) {
    int currentIndex = -1;
    for (int index = 0; index < burnValueArray.length; index++) {
      Duration duration = burnValueArray[index];
      if (seconds == duration.inSeconds) {
        currentIndex = index;
        break;
      }
    }
    List _burnTextArray = <String>[
      NMobileLocalizations.of(context).burn_5_seconds,
      NMobileLocalizations.of(context).burn_10_seconds,
      NMobileLocalizations.of(context).burn_30_seconds,
      NMobileLocalizations.of(context).burn_1_minute,
      NMobileLocalizations.of(context).burn_5_minutes,
      NMobileLocalizations.of(context).burn_10_minutes,
      NMobileLocalizations.of(context).burn_30_minutes,
      NMobileLocalizations.of(context).burn_1_hour,
      NMobileLocalizations.of(context).burn_1_day,
    ];

    if (currentIndex == -1) {
      return '';
    } else {
      return _burnTextArray[currentIndex];
    }
  }

  static showBurnViewDialog(context, contact, chatBloc) async {
    int currentIndex = -1;
    var _sourceOptions = OptionsSchema(deleteAfterSeconds: contact?.options?.deleteAfterSeconds);
    if (_sourceOptions != null && _sourceOptions.deleteAfterSeconds != null && _sourceOptions.deleteAfterSeconds != -1) {
      for (int index = 0; index < burnValueArray.length; index++) {
        Duration duration = burnValueArray[index];
        if (_sourceOptions.deleteAfterSeconds == duration.inSeconds) {
          currentIndex = index;
          break;
        }
      }
    }

    return await showDialog(
      context: context,
      builder: (BuildContext context) {
        return BurnViewPage(
          currentIndex: currentIndex,
          contact: contact,
          chatBloc: chatBloc,
        );
      },
    );
  }
}

class BurnViewPage extends StatefulWidget {
  final int currentIndex;
  final ContactSchema contact;
  final ChatBloc chatBloc;

  BurnViewPage({Key key, this.currentIndex, this.contact, this.chatBloc}) : super(key: key);

  @override
  BurnViewPageState createState() => new BurnViewPageState();
}

class BurnViewPageState extends State<BurnViewPage> with AccountDependsBloc {
  int currentIndex = -1;
  List _burnTextArray;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.currentIndex;
  }

  getItemView(List burnTextArray, context) {
    List<Widget> views = [];
    List<Widget> items = [];
    items.add(SimpleDialogOption(
      child: Row(
        children: <Widget>[
          Container(
              height: 35,
              width: double.infinity,
              child: Row(
                children: <Widget>[
                  Text(NMobileLocalizations.of(context).close),
                ],
              )),
          Spacer(),
          currentIndex == -1
              ? Icon(
                  Icons.check,
                  color: Colors.red,
                  size: 16,
                )
              : Container()
        ],
      ),
      onPressed: () {
        setState(() {
          currentIndex = -1;
        });
      },
    ));
    for (int i = 0; i < burnTextArray.length; i++) {
      var content = burnTextArray[i];
      items.add(SimpleDialogOption(
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 4),
          width: double.infinity,
          child: Row(
            children: <Widget>[
              Text(content),
              Spacer(),
              i == currentIndex
                  ? Icon(
                      Icons.check,
                      color: Colors.red,
                      size: 16,
                    )
                  : Container()
            ],
          ),
        ),
        onPressed: () {
          setState(() {
            currentIndex = i;
          });
        },
      ));
    }
    views.add(Container(
      width: double.infinity,
      child: SingleChildScrollView(
          child: Column(
        children: items,
      )),
    ));

    if (currentIndex != -1) {
      views.add(SimpleDialogOption(child: Container(child: Text('对话接受和发送的消息将于${burnTextArray[currentIndex]}后消失。'))));
    } else {
      views.add(SimpleDialogOption(child: Container(child: Text('对话接受和发送的消息不会消失。'))));
    }

    views.add(Row(
      children: <Widget>[
        Spacer(),
        SimpleDialogOption(
          child: Label(
            NMobileLocalizations.of(context).cancel,
            type: LabelType.bodyRegular,
            color: DefaultTheme.fontColor1,
            textAlign: TextAlign.start,
          ),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        SimpleDialogOption(
          child: Label(
            NMobileLocalizations.of(context).ok,
            type: LabelType.bodyRegular,
            color: DefaultTheme.fontColor1,
            textAlign: TextAlign.start,
          ),
          onPressed: () async {
            setBurnMessage();
          },
        ),
      ],
    ));
    return views;
  }

  setBurnMessage() async {
    var _burnValue;
    if (currentIndex != -1) {
      _burnValue = BurnViewUtil.burnValueArray[currentIndex].inSeconds;
      await widget.contact.setBurnOptions(db, _burnValue);
    } else {
      await widget.contact.setBurnOptions(db, null);
    }
    var sendMsg = MessageSchema.fromSendData(
      from: accountChatId,
      to: widget.contact.clientAddress,
      contentType: ContentType.eventContactOptions,
    );
    sendMsg.isOutbound = true;
    sendMsg.burnAfterSeconds = _burnValue;
    sendMsg.content = sendMsg.toActionContentOptionsData();
    widget.chatBloc.add(SendMessage(sendMsg));
    Navigator.pop(context, _burnValue);
  }

  @override
  Widget build(BuildContext context) {
    if (_burnTextArray == null) {
      _burnTextArray = <String>[
        NMobileLocalizations.of(context).burn_5_seconds,
        NMobileLocalizations.of(context).burn_10_seconds,
        NMobileLocalizations.of(context).burn_30_seconds,
        NMobileLocalizations.of(context).burn_1_minute,
        NMobileLocalizations.of(context).burn_5_minutes,
        NMobileLocalizations.of(context).burn_10_minutes,
        NMobileLocalizations.of(context).burn_30_minutes,
        NMobileLocalizations.of(context).burn_1_hour,
        NMobileLocalizations.of(context).burn_1_day,
      ];
    }
    return Material(
      type: MaterialType.transparency,
      child: SimpleDialog(
        titlePadding: EdgeInsets.fromLTRB(20.0, 20.0, 20.0, 0.0),
        contentPadding: EdgeInsets.fromLTRB(0.0, 12.0, 0.0, 12.0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        title: Text('选择'),
        children: getItemView(_burnTextArray, context),
      ),
    );
  }
}
