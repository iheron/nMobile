import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nmobile/common/client/client.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/common/push/badge.dart' as Badge;
import 'package:nmobile/common/settings.dart';
import 'package:nmobile/components/base/stateful.dart';
import 'package:nmobile/components/button/button.dart';
import 'package:nmobile/components/chat/bottom_menu.dart';
import 'package:nmobile/components/chat/message_item.dart';
import 'package:nmobile/components/chat/send_bar.dart';
import 'package:nmobile/components/contact/header.dart';
import 'package:nmobile/components/dialog/modal.dart';
import 'package:nmobile/components/layout/header.dart';
import 'package:nmobile/components/layout/layout.dart';
import 'package:nmobile/components/private_group/header.dart';
import 'package:nmobile/components/text/label.dart';
import 'package:nmobile/components/tip/toast.dart';
import 'package:nmobile/components/topic/header.dart';
import 'package:nmobile/helpers/file.dart';
import 'package:nmobile/schema/contact.dart';
import 'package:nmobile/schema/device_info.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/private_group.dart';
import 'package:nmobile/schema/session.dart';
import 'package:nmobile/schema/subscriber.dart';
import 'package:nmobile/schema/topic.dart';
import 'package:nmobile/screens/common/media.dart';
import 'package:nmobile/screens/contact/profile.dart';
import 'package:nmobile/screens/private_group/profile.dart';
import 'package:nmobile/screens/private_group/subscribers.dart';
import 'package:nmobile/screens/topic/profile.dart';
import 'package:nmobile/screens/topic/subscribers.dart';
import 'package:nmobile/theme/theme.dart';
import 'package:nmobile/utils/asset.dart';
import 'package:nmobile/utils/format.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/parallel_queue.dart';
import 'package:nmobile/utils/path.dart' as Path2;
import 'package:nmobile/utils/time.dart';

class ChatMessagesScreen extends BaseStateFulWidget {
  static const String routeName = '/chat/messages';
  static final String argTarget = "target";

  static Future go(BuildContext? context, dynamic target) {
    if (context == null) return Future.value(null);
    if (target == null || !((target is ContactSchema) || (target is PrivateGroupSchema) || (target is TopicSchema))) {
      return Future.value(null);
    }
    return Navigator.pushNamed(context, routeName, arguments: {
      argTarget: target,
    });
  }

  final Map<String, dynamic>? arguments;

  const ChatMessagesScreen({Key? key, this.arguments}) : super(key: key);

  @override
  _ChatMessagesScreenState createState() => _ChatMessagesScreenState();
}

class _ChatMessagesScreenState extends BaseStateFulWidgetState<ChatMessagesScreen> with Tag {
  String? _targetId;
  int _targetType = 0;
  dynamic _target;

  bool isClientSendOk = (clientCommon.status != ClientConnectStatus.disconnecting) && (clientCommon.status != ClientConnectStatus.disconnected);

  StreamController<Map<String, String>> _onInputChangeController = StreamController<Map<String, String>>.broadcast();
  StreamSink<Map<String, String>> get _onInputChangeSink => _onInputChangeController.sink;
  Stream<Map<String, String>> get _onInputChangeStream => _onInputChangeController.stream; // .distinct((prev, next) => prev == next);

  StreamSubscription? _clientStatusSubscription;
  StreamSubscription? _appLifeChangeSubscription;

  StreamSubscription? _onContactUpdateStreamSubscription;

  StreamSubscription? _onTopicUpdateStreamSubscription;
  StreamSubscription? _onSubscriberAddStreamSubscription;
  StreamSubscription? _onSubscriberUpdateStreamSubscription;

  StreamSubscription? _onPrivateGroupUpdateStreamSubscription;
  StreamSubscription? _onPrivateGroupItemUpdateStreamSubscription;

  StreamSubscription? _onMessageSaveStreamSubscription;
  StreamSubscription? _onMessageDeleteStreamSubscription;
  StreamSubscription? _onMessageUpdateStreamSubscription;

  StreamSubscription? _onFetchMediasSubscription;

  ScrollController _scrollController = ScrollController();

  ParallelQueue _fetchMsgQueue = ParallelQueue("messages_fetch", onLog: (log, error) => error ? logger.w(log) : null);

  final _pageLimit = 30;
  bool _moreLoading = false;
  List<MessageSchema> _messages = <MessageSchema>[];

  Timer? _delRefreshTimer;

  bool _showBottomMenu = false;

  bool _showRecordLock = false;
  bool _showRecordLockLocked = false;

  @override
  void onRefreshArguments() {
    this._target = widget.arguments?[ChatMessagesScreen.argTarget];
    if (this._target is ContactSchema) {
      this._targetId = (this._target as ContactSchema).address;
      this._targetType = SessionType.CONTACT;
    } else if (this._target is TopicSchema) {
      this._targetId = (this._target as TopicSchema).topicId;
      this._targetType = SessionType.TOPIC;
    } else if (this._target is PrivateGroupSchema) {
      this._targetId = (this._target as PrivateGroupSchema).groupId;
      this._targetType = SessionType.PRIVATE_GROUP;
    }
  }

  @override
  void initState() {
    super.initState();
    messageCommon.chattingTargetId = this._targetId;
    _moreLoading = false;

    // clientStatus
    _clientStatusSubscription = clientCommon.statusStream.distinct((prev, next) => prev == next).listen((int status) {
      if (isClientSendOk != ((clientCommon.status != ClientConnectStatus.disconnecting) && (clientCommon.status != ClientConnectStatus.disconnected))) {
        setState(() {
          isClientSendOk = (clientCommon.status != ClientConnectStatus.disconnecting) && (clientCommon.status != ClientConnectStatus.disconnected);
        });
      }
    });

    // appLife
    _appLifeChangeSubscription = application.appLifeStream.listen((bool inBackground) {
      if (inBackground) {
        audioHelper.playerRelease(); // await
        audioHelper.recordRelease(); // await
      } else {
        int gap = application.goForegroundAt - application.goBackgroundAt;
        if (gap >= Settings.gapClientReAuthMs) {
          // nothing (will go app_screen)
        } else {
          bool isAppForeground = application.appLifecycleState == AppLifecycleState.resumed;
          Future.delayed(Duration(milliseconds: isAppForeground ? 0 : 500)).then((value) {
            _readMessages().then((value) => _clearUnreadAndBadge()); // await
          });
        }
      }
    });

    // contact
    _onContactUpdateStreamSubscription = contactCommon.updateStream.where((event) => (_target is ContactSchema) && (event.address == (_target as ContactSchema).address)).listen((ContactSchema event) {
      setState(() {
        _target = event;
      });
    });

    // topic
    _onTopicUpdateStreamSubscription = topicCommon.updateStream.where((event) => (_target is TopicSchema) && (event.topicId == (_target as TopicSchema).topicId)).listen((event) {
      setState(() {
        _target = event;
      });
      _refreshTopicJoined();
      // _refreshTopicSubscribers();
    });

    // subscriber
    _onSubscriberAddStreamSubscription = subscriberCommon.addStream.where((event) => (_target is TopicSchema) && (event.topicId == (_target as TopicSchema).topicId)).listen((SubscriberSchema schema) {
      if (schema.contactAddress == clientCommon.address) {
        _refreshTopicJoined();
      }
      // _refreshTopicSubscribers();
    });
    _onSubscriberUpdateStreamSubscription = subscriberCommon.updateStream.where((event) => (_target is TopicSchema) && (event.topicId == (_target as TopicSchema).topicId)).listen((event) {
      if (event.contactAddress == clientCommon.address) {
        _refreshTopicJoined();
      } else {
        //_refreshTopicSubscribers();
      }
    });

    // privateGroup
    _onPrivateGroupUpdateStreamSubscription = privateGroupCommon.updateGroupStream.where((event) => (_target is PrivateGroupSchema) && (event.groupId == (_target as PrivateGroupSchema).groupId)).listen((event) {
      setState(() {
        _target = event;
      });
    });
    _onPrivateGroupItemUpdateStreamSubscription = privateGroupCommon.updateGroupItemStream.where((event) => (_target is PrivateGroupSchema) && (event.groupId == (_target as PrivateGroupSchema).groupId)).listen((event) {
      // nothing
    });

    // messages
    _onMessageSaveStreamSubscription = messageCommon.onSavedStream.where((MessageSchema event) => (event.targetId == this._targetId) && (event.targetType == this._targetType)).listen((MessageSchema event) {
      _insertMessage(event); // await
    });
    _onMessageDeleteStreamSubscription = messageCommon.onDeleteStream.listen((event) {
      var messages = _messages.where((element) => element.msgId != event).toList();
      setState(() {
        _messages = messages;
      });
      if (messages.length < (_pageLimit / 2)) {
        _delRefreshTimer?.cancel();
        _delRefreshTimer = null;
        _delRefreshTimer = Timer(Duration(milliseconds: 500), () {
          _getDataMessages(false); // await
        });
      }
    });
    _onMessageUpdateStreamSubscription = messageCommon.onUpdateStream.where((MessageSchema event) => (event.targetId == this._targetId) && (event.targetType == this._targetType)).listen((MessageSchema event) {
      setState(() {
        _messages = _messages.map((MessageSchema e) {
          if (e.msgId == event.msgId) {
            event.temp = e.temp;
            return event;
          }
          return e;
        }).toList();
      });
    });

    // media_screen
    _onFetchMediasSubscription = MediaScreen.onFetchStream.listen((response) async {
      if (response.isEmpty || response[0].isEmpty) return;
      String type = response[0]["type"]?.toString() ?? "";
      if (type != "request") return;
      String target = response[0]["target"]?.toString() ?? "";
      if (target != _targetId) return;
      bool isLeft = response[0]["isLeft"] ?? true;
      String msgId = response[0]["msgId"]?.toString() ?? "";
      // medias
      final limit = 10;
      List<MessageSchema> messages = [];
      List<Map<String, dynamic>> medias = [];
      while (medias.length < limit) {
        List<MessageSchema> msgList = await _getMediasMessages(limit, isLeft, msgId);
        if (msgList.isEmpty) break;
        if (isLeft || messages.isEmpty) {
          messages.addAll(msgList);
        } else {
          messages.insertAll(0, msgList);
        }
        msgId = isLeft ? messages.last.msgId : messages.first.msgId;
        medias = _getMediasData(messages);
      }
      if (medias.isEmpty) return; // no return
      // response
      List<Map<String, dynamic>>? request = MediaScreen.createFetchResponse(target, isLeft, msgId, medias);
      if (request != null) MediaScreen.onFetchSink.add(request);
    });

    // loadMore
    _scrollController.addListener(() {
      double offsetFromBottom = _scrollController.position.maxScrollExtent - _scrollController.position.pixels;
      // logger.d("$TAG - scroll_listen ->>> offsetBottom:$offsetFromBottom = maxScrollExtent:${_scrollController.position.maxScrollExtent} - pixels:${_scrollController.position.pixels}");
      if (offsetFromBottom < 50) {
        _getDataMessages(false); // await
      }
    });

    // messages
    _getDataMessages(true); // await

    // topic
    _refreshTopicJoined(); // await
    _refreshTopicSubscribers(); // await

    // privateGroup
    _checkPrivateGroupVersion(); // await

    // common
    _refreshReceivedMessagesTag();

    // read
    _readMessages().then((value) => _clearUnreadAndBadge()); // await

    // ping
    if (this._targetType == SessionType.CONTACT) {
      chatOutCommon.sendPing([this._targetId ?? ""], true, gap: Settings.gapPingContactMs); // await
      // chatOutCommon.sendPing([this.targetId ?? ""], false, gap: Settings.gapPingContactMs); // await
    } else if (this._targetType == SessionType.TOPIC) {
      // nothing
    } else if (this._targetType == SessionType.PRIVATE_GROUP) {
      // nothing
    }

    // test
    // Future.delayed(Duration(seconds: 1), () => _debugSendText(maxTimes: 99, delayMS: 0));
  }

  /*_debugSendText({int maxTimes = 500, int? delayMS}) async {
    for (var i = 0; i < maxTimes; i++) {
      String content = "${i + 1} _ ${Uuid().v4()}";
      chatOutCommon.sendText(_topic ?? _privateGroup ?? _contact, content);
      if ((delayMS != null) && (delayMS > 0)) await Future.delayed(Duration(milliseconds: delayMS));
    }
  }*/

  @override
  void dispose() {
    messageCommon.chattingTargetId = null;

    audioHelper.playerRelease(); // await
    audioHelper.recordRelease(); // await

    _onInputChangeController.close();
    _clientStatusSubscription?.cancel();
    _appLifeChangeSubscription?.cancel();

    _onContactUpdateStreamSubscription?.cancel();

    _onTopicUpdateStreamSubscription?.cancel();
    _onSubscriberAddStreamSubscription?.cancel();
    _onSubscriberUpdateStreamSubscription?.cancel();

    _onPrivateGroupUpdateStreamSubscription?.cancel();
    _onPrivateGroupItemUpdateStreamSubscription?.cancel();

    _onMessageSaveStreamSubscription?.cancel();
    _onMessageDeleteStreamSubscription?.cancel();
    _onMessageUpdateStreamSubscription?.cancel();

    _onFetchMediasSubscription?.cancel();

    super.dispose();
  }

  Future _getDataMessages(bool refresh) async {
    if (_moreLoading) return;
    _moreLoading = true;
    Function func = () async {
      int _offset = 0;
      if (refresh) {
        _messages = [];
      } else {
        _offset = _messages.length;
      }
      var messages = await messageCommon.queryListByTargetVisible(this._targetId, this._targetType, offset: _offset, limit: _pageLimit);
      _messages = _messages + messages;
      setState(() {});
    };
    await _fetchMsgQueue.add(() => func());
    _moreLoading = false;
  }

  Future _insertMessage(MessageSchema? added) async {
    if (added == null) return;
    // read
    if (!added.isOutbound && messageCommon.isTargetMessagePageVisible(_targetId)) {
      // count not up in chatting
      _readMessages(); // await
    }
    // sender
    if (added.temp == null) added.temp = Map();
    added.temp?["sender"] = await contactCommon.query(added.sender);
    // state
    setState(() {
      // logger.d("$TAG - messages insert 0 - added:$added");
      _messages.insert(0, added);
    });
    // tip
    if (this._targetType == SessionType.CONTACT) {
      Future.delayed(Duration(milliseconds: 100), () => _checkNotificationTip()); // await
    }
  }

  Future _refreshTopicJoined() async {
    if (!clientCommon.isClientOK) return;
    if (this._targetType != SessionType.TOPIC) return;
    TopicSchema _topic = this._target as TopicSchema;
    bool? isJoined = await topicCommon.isSubscribed(_topic.topicId, clientCommon.address);
    if ((isJoined == true) && _topic.isPrivate) {
      SubscriberSchema? _me = await subscriberCommon.query(_topic.topicId, clientCommon.address);
      isJoined = _me?.status == SubscriberStatus.Subscribed;
    }
    if ((isJoined != null) && (isJoined != _topic.joined)) {
      await topicCommon.setJoined(_topic.topicId, isJoined, notify: true);
    }
  }

  Future _refreshTopicSubscribers({bool forceFetch = false}) async {
    if (!clientCommon.isClientOK) return;
    if (this._targetType != SessionType.TOPIC) return;
    TopicSchema _topic = this._target as TopicSchema;
    int lastRefreshAt = _topic.lastRefreshSubscribersAt();
    int interval = DateTime.now().millisecondsSinceEpoch - lastRefreshAt;
    if ((lastRefreshAt == 0) && (_topic.createAt > (DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000))) {
      logger.i("$TAG - _refreshTopicSubscribers - wait sync members - topic:$_topic");
      return;
    } else if ((interval < Settings.gapTopicSubscribersRefreshMs) && !forceFetch) {
      logger.i("$TAG - _refreshTopicSubscribers - gap small - gap:$interval<${Settings.gapTopicSubscribersRefreshMs}");
      return;
    } else {
      logger.i("$TAG - _refreshTopicSubscribers - enable - gap:$interval>${Settings.gapTopicSubscribersRefreshMs}");
    }
    await subscriberCommon.refreshSubscribers(_topic.topicId, _topic.ownerPubKey, meta: _topic.isPrivate);
    await topicCommon.setLastRefreshSubscribersAt(_topic.topicId, notify: true);
    // refresh again
    int count = await subscriberCommon.getSubscribersCount(_topic.topicId, _topic.isPrivate);
    if (_topic.count != count) {
      await topicCommon.setCount(_topic.topicId, count, notify: true);
    }
  }

  Future _checkPrivateGroupVersion() async {
    if (!clientCommon.isClientOK) return;
    if (this._targetType != SessionType.PRIVATE_GROUP) return;
    PrivateGroupSchema _privateGroup = this._target as PrivateGroupSchema;
    if (privateGroupCommon.isOwner(_privateGroup.ownerPublicKey, clientCommon.address)) return;
    await chatOutCommon.sendPrivateGroupOptionRequest(_privateGroup.ownerPublicKey, _privateGroup.groupId, gap: Settings.gapGroupRequestOptionsMs).then((value) {
      if (value) privateGroupCommon.setGroupOptionsRequestInfo(_privateGroup.groupId, _privateGroup.version, notify: true);
    }); // await
  }

  Future _refreshReceivedMessagesTag() async {
    await messageCommon.refreshTargetReceivedMessagesTag(this._targetId, this._targetType);
  }

  Future _readMessages() async {
    await messageCommon.readOtherSideMessagesBySelf(this._targetId, this._targetType);
  }

  Future _clearUnreadAndBadge() async {
    await sessionCommon.setUnReadCount(this._targetId, this._targetType, 0, notify: true);
    SessionSchema? session = await sessionCommon.query(this._targetId, this._targetType);
    Badge.Badge.onCountDown(session?.unReadCount ?? 0); // await
  }

  _toggleBottomMenu() {
    if (mounted) FocusScope.of(context).requestFocus(FocusNode());
    setState(() {
      _showBottomMenu = !_showBottomMenu;
    });
  }

  _hideAll() {
    if (mounted) FocusScope.of(context).requestFocus(FocusNode());
    setState(() {
      _showBottomMenu = false;
    });
  }

  Future _checkNotificationTip() async {
    if (!clientCommon.isClientOK) return;
    if (this._targetType != SessionType.CONTACT) return;
    ContactSchema _contact = this._target as ContactSchema;
    if (_contact.tipNotification) {
      return;
    } else if (_contact.options.notificationOpen) {
      await contactCommon.setTipNotification(_contact.address, null, notify: true);
      return;
    }
    // check
    int sendCount = 0, receiveCount = 0;
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].isOutbound) {
        sendCount++;
      } else {
        receiveCount++;
      }
      if ((sendCount >= 3) && (receiveCount >= 3)) break;
    }
    logger.i("$TAG - _tipNotificationOpen - sendCount:$sendCount - receiveCount:$receiveCount");
    if ((sendCount < 3) || (receiveCount < 3)) return;
    if (messageCommon.chattingTargetId == null) return; // maybe quit page out
    if (!mounted) return; // maybe quit page out
    // tip dialog
    ModalDialog.of(Settings.appContext).confirm(
      title: Settings.locale((s) => s.tip_open_send_device_token),
      hasCloseButton: true,
      agree: Button(
        width: double.infinity,
        text: Settings.locale((s) => s.ok),
        backgroundColor: application.theme.primaryColor,
        onPressed: () {
          if (Navigator.of(this.context).canPop()) Navigator.pop(this.context);
          _toggleNotificationOpen(); // await
        },
      ),
    );
    await contactCommon.setTipNotification(_contact.address, null, notify: true);
  }

  Future _toggleNotificationOpen() async {
    if (this._targetType == SessionType.CONTACT) {
      ContactSchema _contact = this._target as ContactSchema;
      bool nextOpen = !_contact.options.notificationOpen;
      DeviceInfoSchema? deviceInfo = await deviceInfoCommon.getMe(fetchDeviceToken: nextOpen);
      String? deviceToken = nextOpen ? deviceInfo?.deviceToken : null;
      bool tokenEmpty = (deviceToken == null) || deviceToken.isEmpty;
      if (nextOpen && tokenEmpty) {
        Toast.show(Settings.locale((s) => s.unavailable_device));
        return;
      }
      setState(() {
        _contact.options.notificationOpen = nextOpen;
      });
      // update
      var data = await contactCommon.setNotificationOpen(_contact.address, nextOpen, notify: true);
      if (data == null) return;
      chatOutCommon.sendContactOptionsToken(_contact.address, deviceToken).then((success) {
        if (!success) contactCommon.setNotificationOpen(_contact.address, !nextOpen, notify: true); // await
      }); // await
    } else if (this._targetType == SessionType.TOPIC) {
      // nothing
    } else if (this._targetType == SessionType.PRIVATE_GROUP) {
      // nothing
    }
  }

  Future<List<MessageSchema>> _getMediasMessages(int limit, bool isLeft, String msgId) async {
    List<MessageSchema> result = [];
    for (int offset = 0; true; offset += limit) {
      List<MessageSchema> msgList = await messageCommon.queryListByTargetTypesVisible(
        this._targetId,
        this._targetType,
        [MessageContentType.ipfs, MessageContentType.image, MessageContentType.video],
        offset: offset,
        limit: limit,
      );
      if (msgList.isEmpty) break;
      int index = msgList.indexWhere((element) => element.msgId == msgId);
      if (index < 0) continue;
      if (isLeft) {
        offset = offset + index + 1;
      } else {
        offset = offset - limit + index;
        if (offset < 0) {
          offset = 0;
          limit = index;
        }
      }
      result = await messageCommon.queryListByTargetTypesVisible(
        this._targetId,
        this._targetType,
        [MessageContentType.ipfs, MessageContentType.image, MessageContentType.video],
        offset: offset,
        limit: limit,
      );
      break;
    }
    return result;
  }

  List<Map<String, dynamic>> _getMediasData(List<MessageSchema> messages) {
    List<Map<String, dynamic>> medias = [];
    for (var i = 0; i < messages.length; i++) {
      MessageSchema element = messages[i];
      String? path;
      if (element.isContentFile) {
        if ((element.content as File).existsSync()) {
          path = element.content.path;
        }
      } else if (element.content is String) {
        path = element.content;
      }
      if (path == null || path.isEmpty) continue;
      String contentType = element.contentType;
      if (contentType == MessageContentType.ipfs) {
        int? type = MessageOptions.getFileType(element.options);
        if (type == MessageOptions.fileTypeImage) {
          contentType = MessageContentType.image;
        } else if (type == MessageOptions.fileTypeVideo) {
          contentType = MessageContentType.video;
        }
      }
      Map<String, dynamic>? media;
      if (contentType == MessageContentType.image) {
        media = MediaScreen.createMediasItemByImagePath(element.msgId, path);
      } else if (contentType == MessageContentType.video) {
        String? thumbnail = MessageOptions.getMediaThumbnailPath(element.options);
        media = MediaScreen.createMediasItemByVideoPath(element.msgId, path, thumbnail);
      }
      if (media != null) medias.add(media);
    }
    return medias;
  }

  @override
  Widget build(BuildContext context) {
    SkinTheme _theme = application.theme;
    ContactSchema? _contact;
    TopicSchema? _topic;
    PrivateGroupSchema? _privateGroup;
    if (this._targetType == SessionType.CONTACT) {
      _contact = this._target as ContactSchema?;
    } else if (this._targetType == SessionType.TOPIC) {
      _topic = this._target as TopicSchema?;
    } else if (this._targetType == SessionType.PRIVATE_GROUP) {
      _privateGroup = this._target as PrivateGroupSchema?;
    }

    int deleteAfterSeconds = (_topic != null ? _topic.options.deleteAfterSeconds : (_privateGroup != null ? _privateGroup.options.deleteAfterSeconds : _contact?.options.deleteAfterSeconds)) ?? 0;
    Color notifyBellColor = ((_topic != null ? _topic.options.notificationOpen : (_privateGroup != null ? _privateGroup.options.notificationOpen : _contact?.options.notificationOpen)) ?? false) ? application.theme.primaryColor : Colors.white38;

    bool isJoined = (_topic != null) ? (_topic.joined == true) : ((_privateGroup != null) ? (_privateGroup.joined == true) : true);

    String? disableTip;
    if ((_topic != null) && !isJoined) {
      if (_topic.isSubscribeProgress() == true) {
        disableTip = Settings.locale((s) => s.subscribing, ctx: context);
      } else if (_topic.isPrivate == true) {
        disableTip = Settings.locale((s) => s.tip_ask_group_owner_permission, ctx: context);
      } else {
        disableTip = Settings.locale((s) => s.need_re_subscribe, ctx: context);
      }
    } else if (_privateGroup != null) {
      if (_privateGroup.version.isEmpty) {
        disableTip = Settings.locale((s) => s.data_synchronization, ctx: context);
      } else if (!isJoined) {
        disableTip = Settings.locale((s) => s.contact_invite_group_tip, ctx: context);
      }
    }
    if (!isClientSendOk) {
      disableTip = Settings.locale((s) => s.d_chat_not_login, ctx: context);
    }

    return Layout(
      headerColor: _theme.headBarColor2,
      header: Header(
        backgroundColor: _theme.headBarColor2,
        titleChild: Container(
          child: _contact != null
              ? ContactHeader(
                  contact: _contact,
                  onTap: () {
                    ContactProfileScreen.go(context, address: _contact?.address);
                  },
                  body: Container(
                    padding: EdgeInsets.only(top: 3),
                    child: deleteAfterSeconds > 0
                        ? Row(
                            children: [
                              Icon(Icons.alarm_on, size: 16, color: _theme.backgroundLightColor),
                              SizedBox(width: 4),
                              Label(
                                Time.formatDuration(Duration(seconds: deleteAfterSeconds)),
                                type: LabelType.bodySmall,
                                color: _theme.backgroundLightColor,
                              ),
                            ],
                          )
                        : Label(
                            Settings.locale((s) => s.click_to_settings, ctx: context),
                            type: LabelType.h4,
                            color: _theme.fontColor2,
                          ),
                  ),
                )
              : _topic != null
                  ? TopicHeader(
                      topic: _topic,
                      onTap: () {
                        TopicProfileScreen.go(context, topicId: _topic?.topicId);
                      },
                      body: Container(
                        padding: EdgeInsets.only(top: 3),
                        child: deleteAfterSeconds > 0
                            ? Row(
                                children: [
                                  Icon(Icons.alarm_on, size: 16, color: _theme.backgroundLightColor),
                                  SizedBox(width: 4),
                                  Label(
                                    Time.formatDuration(Duration(seconds: deleteAfterSeconds)),
                                    type: LabelType.bodySmall,
                                    color: _theme.backgroundLightColor,
                                  ),
                                ],
                              )
                            : Label(
                                "${_topic.count} ${Settings.locale((s) => s.channel_members, ctx: context)}",
                                type: LabelType.h4,
                                color: _theme.fontColor2,
                              ),
                      ),
                    )
                  : _privateGroup != null
                      ? PrivateGroupHeader(
                          privateGroup: _privateGroup,
                          onTap: () {
                            PrivateGroupProfileScreen.go(context, groupId: _privateGroup?.groupId);
                          },
                          body: Container(
                            padding: EdgeInsets.only(top: 3),
                            child: deleteAfterSeconds > 0
                                ? Row(
                                    children: [
                                      Icon(Icons.alarm_on, size: 16, color: _theme.backgroundLightColor),
                                      SizedBox(width: 4),
                                      Label(
                                        Time.formatDuration(Duration(seconds: deleteAfterSeconds)),
                                        type: LabelType.bodySmall,
                                        color: _theme.backgroundLightColor,
                                      ),
                                    ],
                                  )
                                : Label(
                                    "${_privateGroup.count} ${Settings.locale((s) => s.channel_members, ctx: context)}",
                                    type: LabelType.h4,
                                    color: _theme.fontColor2,
                                  ),
                          ),
                        )
                      : SizedBox.shrink(),
        ),
        actions: [
          _contact != null
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Asset.iconSvg('notification-bell', color: notifyBellColor, width: 24),
                    onPressed: () {
                      _toggleNotificationOpen(); // await
                    },
                  ),
                )
              : SizedBox.shrink(),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _contact != null
                ? IconButton(
                    icon: Asset.iconSvg('more', color: Colors.white, width: 24),
                    onPressed: () {
                      ContactProfileScreen.go(context, address: _contact?.address);
                    },
                  )
                : _topic != null
                    ? IconButton(
                        icon: Asset.iconSvg('group', color: Colors.white, width: 24),
                        onPressed: () {
                          TopicSubscribersScreen.go(context, schema: _topic);
                        },
                      )
                    : _privateGroup != null
                        ? IconButton(
                            icon: Asset.iconSvg('group', color: Colors.white, width: 24),
                            onPressed: () {
                              PrivateGroupSubscribersScreen.go(context, schema: _privateGroup);
                            },
                          )
                        : SizedBox.shrink(),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () {
          _hideAll();
        },
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    ListView.builder(
                      controller: _scrollController,
                      itemCount: _messages.length,
                      reverse: true,
                      padding: const EdgeInsets.only(bottom: 8, top: 16),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemBuilder: (BuildContext context, int index) {
                        if (index < 0 || index >= _messages.length) return SizedBox.shrink();
                        MessageSchema msg = _messages[index];
                        return ChatMessageItem(
                          message: msg,
                          // sender: _sender,
                          // topic: _topic,
                          // privateGroup: _privateGroup,
                          prevMessage: (index - 1) >= 0 ? _messages[index - 1] : null,
                          nextMessage: (index + 1) < _messages.length ? _messages[index + 1] : null,
                          onAvatarPress: (ContactSchema contact, _) {
                            ContactProfileScreen.go(context, schema: contact);
                          },
                          onAvatarLonePress: (ContactSchema contact, _) {
                            _onInputChangeSink.add({"type": ChatSendBar.ChangeTypeAppend, "content": ' @${contact.fullName} '});
                          },
                          onResend: (String msgId) async {
                            MessageSchema? find;
                            var messages = _messages.where((e) {
                              if (e.msgId != msgId) return true;
                              find = e;
                              return false;
                            }).toList();
                            if (find != null) messages.insert(0, find!);
                            this.setState(() {
                              _messages = messages;
                            });
                            await chatOutCommon.resend(msgId);
                          },
                        );
                      },
                    ),
                    _showRecordLock
                        ? Positioned(
                            width: ChatSendBar.LockActionSize,
                            height: ChatSendBar.LockActionSize,
                            right: ChatSendBar.LockActionMargin,
                            bottom: ChatSendBar.LockActionMargin,
                            child: Container(
                              width: ChatSendBar.LockActionSize,
                              height: ChatSendBar.LockActionSize,
                              decoration: BoxDecoration(
                                color: _showRecordLockLocked ? Colors.red : Colors.white,
                                borderRadius: BorderRadius.all(Radius.circular(ChatSendBar.LockActionSize / 2)),
                              ),
                              child: UnconstrainedBox(
                                child: Asset.iconSvg(
                                  'lock',
                                  width: ChatSendBar.LockActionSize / 2,
                                  color: _showRecordLockLocked ? Colors.white : Colors.red,
                                ),
                              ),
                            ),
                          )
                        : SizedBox.shrink(),
                  ],
                ),
              ),
              Divider(height: 1, color: _theme.backgroundColor2),
              ChatSendBar(
                targetId: this._targetId,
                disableTip: disableTip,
                onMenuPressed: () {
                  _toggleBottomMenu();
                },
                onSendPress: (String content) {
                  return chatOutCommon.sendText(this._target, content); // await
                },
                onInputFocus: (bool focus) {
                  if (focus && _showBottomMenu) {
                    setState(() {
                      _showBottomMenu = false;
                    });
                  }
                },
                onRecordTap: (bool visible, bool complete, int durationMs) async {
                  if (visible) {
                    String? savePath = await audioHelper.recordStart(
                      this._targetId ?? "",
                      maxDurationS: Settings.durationAudioRecordMaxS,
                    );
                    if (savePath == null || savePath.isEmpty) {
                      Toast.show(Settings.locale((s) => s.failure, ctx: context));
                      await audioHelper.recordStop();
                      return false;
                    }
                    return true;
                  } else {
                    if (durationMs < Settings.durationAudioRecordMinS * 1000) {
                      await audioHelper.recordStop();
                      return null;
                    }
                    String? savePath = await audioHelper.recordStop();
                    if (savePath == null || savePath.isEmpty) {
                      Toast.show(Settings.locale((s) => s.failure, ctx: context));
                      await audioHelper.recordStop();
                      return null;
                    }
                    File content = File(savePath);
                    if (!complete) {
                      if (await content.exists()) {
                        await content.delete();
                      }
                      await audioHelper.recordStop();
                      return null;
                    }
                    int size = await content.length();
                    logger.d("$TAG - onRecordTap - saveFileSize:${Format.flowSize(size.toDouble(), unitArr: ['B', 'KB', 'MB', 'GB'])}");
                    if (size <= Settings.piecesMaxSize) {
                      chatOutCommon.sendAudio(this._target, content, durationMs / 1000); // await
                      return true;
                    } else {
                      chatOutCommon.saveIpfs(this._target, {
                        "path": savePath,
                        "size": size,
                        "name": "",
                        "fileExt": Path2.Path.getFileExt(content, FileHelper.DEFAULT_AUDIO_EXT),
                        "mimeType": "audio",
                        "duration": durationMs / 1000,
                      }); // await
                      return true;
                    }
                  }
                },
                onRecordLock: (bool visible, bool lock) {
                  if (_showRecordLock != visible || _showRecordLockLocked != lock) {
                    setState(() {
                      _showRecordLock = visible;
                      _showRecordLockLocked = lock;
                    });
                  }
                  return true;
                },
                onChangeStream: _onInputChangeStream,
              ),
              isClientSendOk && isJoined
                  ? ChatBottomMenu(
                      target: _targetId,
                      show: _showBottomMenu,
                      onPicked: (List<Map<String, dynamic>> results) async {
                        if (mounted) FocusScope.of(context).requestFocus(FocusNode());
                        if (results.isEmpty) return;
                        for (var i = 0; i < results.length; i++) {
                          Map<String, dynamic> result = results[i];
                          String path = result["path"] ?? "";
                          int size = int.tryParse(result["size"]?.toString() ?? "") ?? File(path).lengthSync();
                          String? mimeType = result["mimeType"];
                          double durationS = double.tryParse(result["duration"]?.toString() ?? "") ?? 0;
                          if (path.isEmpty) continue;
                          // no message_type(video/file), and result no mime_type from file_picker
                          // so big_file and video+file go with type_ipfs
                          if ((mimeType?.contains("image") == true) && (size <= Settings.piecesMaxSize)) {
                            chatOutCommon.sendImage(this._target, File(path)); // await
                          } else if ((mimeType?.contains("audio") == true) && (size <= Settings.piecesMaxSize)) {
                            chatOutCommon.sendAudio(this._target, File(path), durationS); // await
                          } else {
                            chatOutCommon.saveIpfs(this._target, result); // await
                          }
                        }
                      },
                    )
                  : SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }
}
