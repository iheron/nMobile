import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nkn_sdk_flutter/crypto.dart';
import 'package:nkn_sdk_flutter/utils/hex.dart';
import 'package:nmobile/common/client/client.dart';
import 'package:nmobile/common/global.dart';
import 'package:nmobile/common/locator.dart';
import 'package:nmobile/components/tip/toast.dart';
import 'package:nmobile/schema/message.dart';
import 'package:nmobile/schema/option.dart';
import 'package:nmobile/schema/private_group.dart';
import 'package:nmobile/schema/private_group_item.dart';
import 'package:nmobile/schema/session.dart';
import 'package:nmobile/storages/private_group.dart';
import 'package:nmobile/storages/private_group_item.dart';
import 'package:nmobile/utils/hash.dart';
import 'package:nmobile/utils/logger.dart';
import 'package:nmobile/utils/util.dart';
import 'package:uuid/uuid.dart';

class PrivateGroupCommon with Tag {
  // ignore: close_sinks
  StreamController<PrivateGroupSchema> _addGroupController = StreamController<PrivateGroupSchema>.broadcast();
  StreamSink<PrivateGroupSchema> get _addGroupSink => _addGroupController.sink;
  Stream<PrivateGroupSchema> get addGroupStream => _addGroupController.stream;

  // ignore: close_sinks
  StreamController<PrivateGroupSchema> _updateGroupController = StreamController<PrivateGroupSchema>.broadcast();
  StreamSink<PrivateGroupSchema> get _updateGroupSink => _updateGroupController.sink;
  Stream<PrivateGroupSchema> get updateGroupStream => _updateGroupController.stream;

  // ignore: close_sinks
  StreamController<PrivateGroupItemSchema> _addGroupItemController = StreamController<PrivateGroupItemSchema>.broadcast();
  StreamSink<PrivateGroupItemSchema> get _addGroupItemSink => _addGroupItemController.sink;
  Stream<PrivateGroupItemSchema> get addGroupItemStream => _addGroupItemController.stream;

  // ignore: close_sinks
  StreamController<PrivateGroupItemSchema> _updateGroupItemController = StreamController<PrivateGroupItemSchema>.broadcast();
  StreamSink<PrivateGroupItemSchema> get _updateGroupItemSink => _updateGroupItemController.sink;
  Stream<PrivateGroupItemSchema> get updateGroupItemStream => _updateGroupItemController.stream;

  ///****************************************** Member *******************************************

  PrivateGroupItemSchema? createInvitationModel(String? groupId, String? invitee, String? inviter, {int? permission, int? expiresMs}) {
    if (groupId == null || groupId.isEmpty) return null;
    if (invitee == null || invitee.isEmpty) return null;
    if (inviter == null || inviter.isEmpty) return null;
    int nowAt = DateTime.now().millisecondsSinceEpoch;
    int expiresAt = nowAt + (expiresMs ?? Global.privateGroupInviteExpiresMs);
    PrivateGroupItemSchema? schema = PrivateGroupItemSchema.create(
      groupId,
      permission: permission ?? PrivateGroupItemPerm.normal,
      expiresAt: expiresAt,
      invitee: invitee,
      inviter: inviter,
    );
    if (schema == null) return null;
    schema.inviterRawData = jsonEncode(schema.createRawDataMap());
    return schema;
  }

  Future<PrivateGroupSchema?> createPrivateGroup(String? name, {bool toast = false}) async {
    if (name == null || name.isEmpty) return null;
    String? ownerPublicKey = clientCommon.getPublicKey();
    if (ownerPublicKey == null || ownerPublicKey.isEmpty) return null;
    String groupId = '$ownerPublicKey.${Uuid().v4().replaceAll("-", "")}';
    // group
    PrivateGroupSchema? schemaGroup = PrivateGroupSchema.create(groupId, name);
    if (schemaGroup == null) return null;
    Uint8List? clientSeed = clientCommon.client?.seed;
    if (clientSeed == null) return null;
    Uint8List ownerPrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    String? signatureData = await genSignature(ownerPrivateKey, jsonEncode(schemaGroup.getRawDataMap()));
    if (signatureData == null || signatureData.isEmpty) {
      logger.e('$TAG - createPrivateGroup - group sign create fail. - pk:$ownerPrivateKey - group:$schemaGroup');
      return null;
    }
    schemaGroup.setSignature(signatureData);
    // item
    String? selfAddress = clientCommon.address;
    if (selfAddress == null || selfAddress.isEmpty) return null;
    PrivateGroupItemSchema? schemaItem = createInvitationModel(groupId, selfAddress, selfAddress, permission: PrivateGroupItemPerm.owner);
    if (schemaItem == null) return null;
    schemaItem.inviterSignature = await genSignature(ownerPrivateKey, schemaItem.inviterRawData);
    if ((schemaItem.inviterSignature == null) || (schemaItem.inviterSignature?.isEmpty == true)) {
      logger.e('$TAG - createPrivateGroup - inviter sign create fail. - pk:$ownerPrivateKey - member:$schemaItem');
      return null;
    }
    // accept self
    schemaItem = await acceptInvitation(schemaItem, inviteePrivateKey: ownerPrivateKey, toast: toast);
    schemaItem = (await addPrivateGroupItem(schemaItem, true, notify: true)) ?? (await queryGroupItem(groupId, ownerPublicKey));
    if (schemaItem == null) {
      logger.e('$TAG - createPrivateGroup - member create fail. - member:$schemaItem');
      return null;
    }
    // insert
    schemaGroup.version = genPrivateGroupVersion(1, schemaGroup.signature, getInviteesKey([schemaItem]));
    schemaGroup.joined = true;
    schemaGroup.count = 1;
    schemaGroup = await addPrivateGroup(schemaGroup, false, notify: true, checkDuplicated: false);
    return schemaGroup;
  }

  Future<bool> invitee(String? groupId, String? target, {bool toast = false}) async {
    if (target == null || target.isEmpty) return false;
    if (groupId == null || groupId.isEmpty) return false;
    // check
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - invitee - has no group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.group_no_exist));
      return false;
    }
    String? selfAddress = clientCommon.address;
    if ((target == selfAddress) || (selfAddress == null) || selfAddress.isEmpty) {
      logger.e('$TAG - invitee - invitee self. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.invite_yourself_error));
      return false;
    }
    PrivateGroupItemSchema? myself = await queryGroupItem(groupId, selfAddress);
    PrivateGroupItemSchema? invitee = await queryGroupItem(groupId, target);
    if ((myself == null) || ((myself.permission ?? 0) <= PrivateGroupItemPerm.none)) {
      logger.e('$TAG - invitee - me no in group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.contact_invite_group_tip));
      return false;
    } else if ((invitee != null) && ((invitee.permission ?? 0) > PrivateGroupItemPerm.none)) {
      logger.d('$TAG - invitee - Invitee already exists.');
      if (toast) Toast.show(Global.locale((s) => s.invitee_already_exists));
      return false;
    } else if ((invitee != null) && (invitee.permission == PrivateGroupItemPerm.black)) {
      logger.d('$TAG - invitee - Invitee again black.');
      invitee.permission = PrivateGroupItemPerm.none;
      await updateGroupItemPermission(invitee, false);
    }
    if (isAdmin(schemaGroup, myself)) {
      if (isOwner(schemaGroup.ownerPublicKey, myself.invitee)) {
        // nothing
      } else {
        logger.d('$TAG - invitee - Invitee no owner.');
        // FUTURE:GG PG admin invitee (send msg to invitee and let owner to receive+sync)
        return false;
      }
    } else {
      logger.d('$TAG - invitee - Invitee no adminer.');
      if (toast) Toast.show(Global.locale((s) => s.no_permission_action));
      return false;
    }
    // action
    if (invitee == null) {
      invitee = createInvitationModel(groupId, target, selfAddress);
    } else {
      invitee.permission = PrivateGroupItemPerm.normal;
      invitee.expiresAt = DateTime.now().millisecondsSinceEpoch + Global.privateGroupInviteExpiresMs;
      invitee.inviterRawData = jsonEncode(invitee.createRawDataMap());
    }
    if (invitee == null) return false;
    Uint8List? clientSeed = clientCommon.client?.seed;
    if (clientSeed == null) return false;
    Uint8List inviterPrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    invitee.inviterSignature = await genSignature(inviterPrivateKey, invitee.inviterRawData);
    if ((invitee.inviterSignature == null) || (invitee.inviterSignature?.isEmpty == true)) return false;
    chatOutCommon.sendPrivateGroupInvitee(target, schemaGroup, invitee); // await
    return true;
  }

  Future<PrivateGroupItemSchema?> acceptInvitation(PrivateGroupItemSchema? schema, {Uint8List? inviteePrivateKey, bool toast = false}) async {
    if (schema == null || schema.groupId.isEmpty) return null;
    // duplicated
    PrivateGroupItemSchema? itemExists = await queryGroupItem(schema.groupId, schema.invitee);
    if ((itemExists != null) && ((itemExists.permission ?? 0) > PrivateGroupItemPerm.none)) {
      logger.w('$TAG - acceptInvitation - already in group - exists:$itemExists');
      if (toast) Toast.show(Global.locale((s) => s.accepted_already));
      return null;
    }
    // check
    int? expiresAt = schema.expiresAt;
    int nowAt = DateTime.now().millisecondsSinceEpoch;
    if ((expiresAt == null) || (expiresAt < nowAt)) {
      logger.w('$TAG - acceptInvitation - expiresAt check fail - expiresAt:$expiresAt - nowAt:$nowAt');
      if (toast) Toast.show(Global.locale((s) => s.invitation_has_expired));
      return null;
    }
    if ((schema.invitee == null) || (schema.invitee?.isEmpty == true) || (schema.inviter == null) || (schema.inviter?.isEmpty == true) || (schema.inviterRawData == null) || (schema.inviterRawData?.isEmpty == true) || (schema.inviterSignature == null) || (schema.inviterSignature?.isEmpty == true)) {
      logger.e('$TAG - acceptInvitation - inviter incomplete data - schema:$schema');
      if (toast) Toast.show(Global.locale((s) => s.invitation_information_error));
      return null;
    }
    bool verifiedInviter = await verifiedSignature(schema.inviter, schema.inviterRawData, schema.inviterSignature);
    if (!verifiedInviter) {
      logger.e('$TAG - acceptInvitation - signature verification failed.');
      if (toast) Toast.show(Global.locale((s) => s.invitation_signature_error));
      return null;
    }
    // set
    if (inviteePrivateKey == null) {
      Uint8List? clientSeed = clientCommon.client?.seed;
      if (clientSeed == null) return null;
      inviteePrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    }
    schema.inviteeRawData = jsonEncode(schema.createRawDataMap());
    schema.inviteeSignature = await genSignature(inviteePrivateKey, schema.inviteeRawData);
    if ((schema.inviteeSignature == null) || (schema.inviteeSignature?.isEmpty == true)) return null;
    return schema;
  }

  Future<PrivateGroupSchema?> onInviteeAccept(PrivateGroupItemSchema? schema, {bool notify = false}) async {
    if (schema == null || schema.groupId.isEmpty) return null;
    // check
    int? expiresAt = schema.expiresAt;
    int nowAt = DateTime.now().millisecondsSinceEpoch;
    if ((expiresAt == null) || (expiresAt < nowAt)) {
      logger.w('$TAG - onInviteeAccept - time check fail - expiresAt:$expiresAt - nowAt:$nowAt');
      return null;
    }
    if ((schema.invitee == null) || (schema.invitee?.isEmpty == true) || (schema.inviter == null) || (schema.inviter?.isEmpty == true) || (schema.inviterRawData == null) || (schema.inviterRawData?.isEmpty == true) || (schema.inviteeRawData == null) || (schema.inviteeRawData?.isEmpty == true) || (schema.inviterSignature == null) || (schema.inviterSignature?.isEmpty == true) || (schema.inviteeSignature == null) || (schema.inviteeSignature?.isEmpty == true)) {
      logger.e('$TAG - onInviteeAccept - inviter incomplete data - schema:$schema');
      return null;
    }
    bool verifiedInviter = await verifiedSignature(schema.inviter, schema.inviterRawData, schema.inviterSignature);
    bool verifiedInvitee = await verifiedSignature(schema.invitee, schema.inviteeRawData, schema.inviteeSignature);
    if (!verifiedInviter || !verifiedInvitee) {
      logger.e('$TAG - onInviteeAccept - signature verification failed. - verifiedInviter:$verifiedInviter - verifiedInvitee:$verifiedInvitee');
      return null;
    }
    // exists
    PrivateGroupSchema? schemaGroup = await queryGroup(schema.groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - onInviteeAccept - has no group. - groupId:${schema.groupId}');
      return null;
    }
    PrivateGroupItemSchema? itemExist = await queryGroupItem(schema.groupId, schema.invitee);
    if ((itemExist != null) && ((itemExist.permission ?? 0) > PrivateGroupItemPerm.none)) {
      logger.i('$TAG - onInviteeAccept - invitee is exist.');
      return schemaGroup;
    } else if ((itemExist != null) && (itemExist.permission == PrivateGroupItemPerm.quit)) {
      if ((expiresAt - Global.privateGroupInviteExpiresMs) < (itemExist.expiresAt ?? 0)) {
        logger.i('$TAG - onInviteeAccept - invitee later by quit.');
        return null;
      }
    } else if ((itemExist != null) && (itemExist.permission == PrivateGroupItemPerm.black)) {
      logger.i('$TAG - onInviteeAccept - invitee is black.');
      return null;
    }
    // member
    if (itemExist == null) {
      schema = await addPrivateGroupItem(schema, true, notify: true, checkDuplicated: false);
    } else {
      bool success = await updateGroupItemPermission(schema, true, notify: true);
      if (!success) schema = null;
    }
    if (schema == null) {
      logger.e('$TAG - onInviteeAccept - member create fail. - member:$schema');
      return null;
    }
    // members
    List<PrivateGroupItemSchema> members = await getMembersAll(schema.groupId);
    // group
    int commits = (getPrivateGroupVersionCommits(schemaGroup.version) ?? 0) + 1;
    schemaGroup.version = genPrivateGroupVersion(commits, schemaGroup.signature, getInviteesKey(members));
    schemaGroup.count = members.length;
    bool success = await updateGroupVersionCount(schema.groupId, schemaGroup.version, schemaGroup.count ?? 0, notify: true);
    return success ? schemaGroup : null;
  }

  Future<bool> quit(String? groupId, {bool toast = false, bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    // check
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - quit - has no group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.group_no_exist));
      return false;
    }
    String? selfAddress = clientCommon.address;
    if ((selfAddress == null) || selfAddress.isEmpty) {
      logger.w('$TAG - quit - groupId:$groupId - selfAddress:$selfAddress');
      return false;
    } else if (isOwner(schemaGroup.ownerPublicKey, selfAddress)) {
      logger.e('$TAG - quit - owner quit deny. - groupId:$groupId');
      return false;
    }
    PrivateGroupItemSchema? myself = await queryGroupItem(groupId, selfAddress);
    if ((myself == null) || ((myself.permission ?? 0) <= PrivateGroupItemPerm.none)) {
      logger.d('$TAG - quit - Member already no exists.');
      if (toast) Toast.show(Global.locale((s) => s.tip_ask_group_owner_permission));
      return false;
    }
    // join (no item modify to avoid be sync members by different group_version)
    schemaGroup.joined = false;
    bool success = await updateGroupJoined(groupId, schemaGroup.joined, notify: notify);
    if (!success) {
      logger.e('$TAG - quit - quit group join sql fail.');
      return false;
    }
    // message
    List<PrivateGroupItemSchema> owners = await queryMembers(groupId, perm: PrivateGroupItemPerm.owner, limit: 1);
    if (owners.length <= 0) return false;
    chatOutCommon.sendPrivateGroupQuit(owners[0].inviter, schemaGroup.groupId); // await
    return true;
  }

  Future<bool> onMemberQuit(String? target, String? groupId, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    if (target == null || target.isEmpty) return false;
    // check
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - onMemberQuit - has no group. - groupId:$groupId');
      return false;
    }
    String? selfAddress = clientCommon.address;
    if ((target == selfAddress) || (selfAddress == null) || selfAddress.isEmpty) {
      logger.w('$TAG - onMemberQuit - groupId:$groupId - target:$target');
      return false;
    }
    PrivateGroupItemSchema? myself = await queryGroupItem(groupId, selfAddress);
    PrivateGroupItemSchema? lefter = await queryGroupItem(groupId, target);
    if ((myself == null) || ((myself.permission ?? 0) <= PrivateGroupItemPerm.none)) {
      logger.w('$TAG - onMemberQuit - me no in group. - groupId:$groupId');
      return false;
    } else if ((lefter == null) || ((lefter.permission ?? 0) < PrivateGroupItemPerm.none)) {
      logger.d('$TAG - onMemberQuit - Member already no exists.');
      return false;
    }
    if (isAdmin(schemaGroup, myself)) {
      if (isOwner(schemaGroup.ownerPublicKey, myself.invitee)) {
        // nothing
      } else {
        logger.d('$TAG - onMemberQuit - onQuit no owner.');
        // FUTURE:GG PG admin kickOut (send msg to kickOut and let owner to receive+sync)
        return false;
      }
    } else {
      logger.d('$TAG - onMemberQuit - onQuit no adminer.');
      return false;
    }
    // action
    Uint8List? clientSeed = clientCommon.client?.seed;
    if (clientSeed == null) return false;
    Uint8List inviterPrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    lefter.permission = PrivateGroupItemPerm.quit;
    lefter.expiresAt = DateTime.now().millisecondsSinceEpoch;
    lefter.inviterRawData = jsonEncode(lefter.createRawDataMap());
    lefter.inviteeRawData = "";
    lefter.inviterSignature = await genSignature(inviterPrivateKey, lefter.inviterRawData);
    lefter.inviteeSignature = "";
    if ((lefter.inviterSignature == null) || (lefter.inviterSignature?.isEmpty == true)) return false;
    bool success = await updateGroupItemPermission(lefter, true, notify: notify);
    if (!success) {
      logger.e('$TAG - onMemberQuit - kickOut member sql fail.');
      return false;
    }
    // members
    List<PrivateGroupItemSchema> members = await getMembersAll(schemaGroup.groupId);
    List<String> memberKeys = getInviteesKey(members);
    // group
    int commits = (getPrivateGroupVersionCommits(schemaGroup.version) ?? 0) + 1;
    schemaGroup.version = genPrivateGroupVersion(commits, schemaGroup.signature, memberKeys);
    schemaGroup.count = members.length;
    success = await updateGroupVersionCount(schemaGroup.groupId, schemaGroup.version, schemaGroup.count ?? 0, notify: notify);
    if (!success) {
      logger.e('$TAG - onMemberQuit - kickOut group sql fail.');
      return false;
    }
    // sync members
    members.add(lefter);
    members.forEach((m) {
      if (m.invitee != selfAddress) {
        chatOutCommon.sendPrivateGroupMemberResponse(m.invitee, schemaGroup, [lefter]).then((value) {
          chatOutCommon.sendPrivateGroupOptionResponse(m.invitee, schemaGroup); // await
        });
      }
    });
    return true;
  }

  Future<bool> kickOut(String? groupId, String? target, {bool notify = false, bool toast = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    if (target == null || target.isEmpty) return false;
    // check
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - kickOut - has no group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.group_no_exist));
      return false;
    }
    String? selfAddress = clientCommon.address;
    if ((target == selfAddress) || (selfAddress == null) || selfAddress.isEmpty) {
      logger.w('$TAG - kickOut - kickOut self. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.kick_yourself_error));
      return false;
    }
    PrivateGroupItemSchema? myself = await queryGroupItem(groupId, selfAddress);
    PrivateGroupItemSchema? blacker = await queryGroupItem(groupId, target);
    if ((myself == null) || ((myself.permission ?? 0) <= PrivateGroupItemPerm.none)) {
      logger.w('$TAG - kickOut - me no in group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.contact_invite_group_tip));
      return false;
    } else if ((blacker == null) || ((blacker.permission ?? 0) <= PrivateGroupItemPerm.none)) {
      logger.d('$TAG - kickOut - Member already no exists.');
      if (toast) Toast.show(Global.locale((s) => s.member_already_no_permission));
      return false;
    }
    if (isAdmin(schemaGroup, myself)) {
      if (isOwner(schemaGroup.ownerPublicKey, myself.invitee)) {
        // nothing
      } else {
        logger.d('$TAG - kickOut - kickOut no owner.');
        // FUTURE:GG PG admin kickOut (send msg to kickOut and let owner to receive+sync)
        return false;
      }
    } else {
      logger.d('$TAG - kickOut - kickOut no adminer.');
      if (toast) Toast.show(Global.locale((s) => s.no_permission_action));
      return false;
    }
    // action
    Uint8List? clientSeed = clientCommon.client?.seed;
    if (clientSeed == null) return false;
    Uint8List inviterPrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    blacker.permission = PrivateGroupItemPerm.black;
    blacker.expiresAt = DateTime.now().millisecondsSinceEpoch;
    blacker.inviterRawData = jsonEncode(blacker.createRawDataMap());
    blacker.inviteeRawData = "";
    blacker.inviterSignature = await genSignature(inviterPrivateKey, blacker.inviterRawData);
    blacker.inviteeSignature = "";
    if ((blacker.inviterSignature == null) || (blacker.inviterSignature?.isEmpty == true)) return false;
    bool success = await updateGroupItemPermission(blacker, true, notify: notify);
    if (!success) {
      logger.e('$TAG - kickOut - kickOut member sql fail.');
      return false;
    }
    // members
    List<PrivateGroupItemSchema> members = await getMembersAll(schemaGroup.groupId);
    List<String> memberKeys = getInviteesKey(members);
    // group
    int commits = (getPrivateGroupVersionCommits(schemaGroup.version) ?? 0) + 1;
    schemaGroup.version = genPrivateGroupVersion(commits, schemaGroup.signature, memberKeys);
    schemaGroup.count = members.length;
    success = await updateGroupVersionCount(schemaGroup.groupId, schemaGroup.version, schemaGroup.count ?? 0, notify: notify);
    if (!success) {
      logger.e('$TAG - kickOut - kickOut group sql fail.');
      return false;
    }
    // sync members
    members.add(blacker);
    members.forEach((m) {
      if (m.invitee != selfAddress) {
        chatOutCommon.sendPrivateGroupMemberResponse(m.invitee, schemaGroup, [blacker]).then((value) {
          chatOutCommon.sendPrivateGroupOptionResponse(m.invitee, schemaGroup); // await
        });
      }
    });
    return true;
  }

  ///****************************************** Action *******************************************

  Future<bool> setOptionsBurning(String? groupId, int? burningSeconds, {bool notify = false, bool toast = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    // check
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - setOptionsBurning - has no group. - groupId:$groupId');
      if (toast) Toast.show(Global.locale((s) => s.group_no_exist));
      return false;
    }
    String? selfAddress = clientCommon.address;
    if ((selfAddress == null) || selfAddress.isEmpty || !isOwner(schemaGroup.ownerPublicKey, selfAddress)) {
      logger.w('$TAG - setOptionsBurning - no permission.');
      if (toast) Toast.show(Global.locale((s) => s.only_owner_can_modify));
      return false;
    }
    // delete_sec
    if (schemaGroup.options == null) schemaGroup.options = OptionsSchema();
    schemaGroup.options?.deleteAfterSeconds = burningSeconds;
    bool success = await setGroupOptionsBurn(schemaGroup, schemaGroup.options?.deleteAfterSeconds, notify: notify);
    if (!success) {
      logger.e('$TAG - setOptionsBurning - options sql fail.');
      return false;
    }
    // signature
    Uint8List? clientSeed = clientCommon.client?.seed;
    if (clientSeed == null) return false;
    Uint8List ownerPrivateKey = await Crypto.getPrivateKeyFromSeed(clientSeed);
    String? signatureData = await genSignature(ownerPrivateKey, jsonEncode(schemaGroup.getRawDataMap()));
    schemaGroup.setSignature(signatureData);
    if (signatureData == null || signatureData.isEmpty) {
      logger.e('$TAG - setOptionsBurning - group sign create fail. - pk:$ownerPrivateKey - group:$schemaGroup');
      return false;
    }
    // version
    List<PrivateGroupItemSchema> members = await getMembersAll(schemaGroup.groupId);
    int commits = (getPrivateGroupVersionCommits(schemaGroup.version) ?? 0) + 1;
    schemaGroup.version = genPrivateGroupVersion(commits, schemaGroup.signature, getInviteesKey(members));
    if ((schemaGroup.version == null) || (schemaGroup.version?.isEmpty == true)) {
      logger.e('$TAG - setOptionsBurning - version update fail.');
      return false;
    }
    success = await updateGroupVersionCount(schemaGroup.groupId, schemaGroup.version, schemaGroup.count ?? 0, notify: notify);
    if (!success) {
      logger.e('$TAG - setOptionsBurning - version sql fail.');
      return false;
    }
    // sync members
    members.forEach((m) {
      if (m.invitee != selfAddress) {
        chatOutCommon.sendPrivateGroupOptionResponse(m.invitee, schemaGroup); // await
      }
    });
    return true;
  }

  ///****************************************** Sync *******************************************

  Future<bool> pushPrivateGroupOptions(String? target, String? groupId, String? remoteVersion, {bool force = false}) async {
    if (target == null || target.isEmpty) return false;
    if (groupId == null || groupId.isEmpty) return false;
    // group
    PrivateGroupSchema? privateGroup = await queryGroup(groupId);
    if (privateGroup == null) return false;
    // version
    if (!force && (remoteVersion != null) && remoteVersion.isNotEmpty) {
      bool? versionOk = await verifiedGroupVersion(privateGroup, remoteVersion, skipCommits: false);
      if (versionOk == true) {
        logger.d('$TAG - pushPrivateGroupOptions - version same - version:$remoteVersion');
        return false;
      }
    }
    // item
    PrivateGroupItemSchema? privateGroupItem = await queryGroupItem(groupId, target);
    if (privateGroupItem == null) {
      logger.e('$TAG - pushPrivateGroupOptions - request is not in group.');
      return false;
    } else if ((privateGroupItem.permission ?? 0) <= PrivateGroupItemPerm.none) {
      return await pushPrivateGroupMembers(target, groupId, remoteVersion, force: true);
    }
    // send
    chatOutCommon.sendPrivateGroupOptionResponse(target, privateGroup); // await
    return true;
  }

  Future<PrivateGroupSchema?> updatePrivateGroupOptions(String? groupId, String? rawData, String? version, int? count, String? signature) async {
    if (groupId == null || groupId.isEmpty) return null;
    if (rawData == null || rawData.isEmpty) return null;
    if (version == null || version.isEmpty) return null;
    if (count == null) return null;
    if (signature == null || signature.isEmpty) return null;
    Map infos = Util.jsonFormatMap(rawData) ?? Map();
    // verified
    String ownerPubKey = getOwnerPublicKey(groupId);
    bool verifiedGroup = await verifiedSignature(ownerPubKey, rawData, signature);
    if (!verifiedGroup) {
      logger.e('$TAG - updatePrivateGroupOptions - signature verification failed.');
      return null;
    }
    // check
    PrivateGroupSchema? exists = await queryGroup(groupId);
    if (exists == null) {
      PrivateGroupSchema? _newGroup = PrivateGroupSchema.create(groupId, infos['name'], type: infos['type']);
      if (_newGroup == null) return null;
      _newGroup.version = version;
      _newGroup.count = count;
      _newGroup.options = OptionsSchema(deleteAfterSeconds: int.tryParse(infos['deleteAfterSeconds']?.toString() ?? ""));
      _newGroup.setSignature(signature);
      exists = await addPrivateGroup(_newGroup, true, notify: true, checkDuplicated: false);
      logger.i('$TAG - updatePrivateGroupOptions - group create - group:$exists');
    } else {
      int nativeVersionCommits = getPrivateGroupVersionCommits(exists.version) ?? 0;
      int remoteVersionCommits = getPrivateGroupVersionCommits(version) ?? 0;
      if (nativeVersionCommits < remoteVersionCommits) {
        bool verifiedGroup = await verifiedSignature(exists.ownerPublicKey, jsonEncode(exists.getRawDataMap()), signature);
        if (!verifiedGroup) {
          String? name = infos['name'];
          int? type = int.tryParse(infos['type']?.toString() ?? "");
          int? deleteAfterSeconds = int.tryParse(infos['deleteAfterSeconds']?.toString() ?? "");
          if ((name != exists.name) || (type != exists.type)) {
            exists.name = name ?? exists.name;
            exists.type = type ?? exists.type;
            await updateGroupNameType(groupId, exists.name, exists.type, notify: true);
          }
          if (deleteAfterSeconds != exists.options?.deleteAfterSeconds) {
            if (exists.options == null) exists.options = OptionsSchema();
            exists.options?.deleteAfterSeconds = deleteAfterSeconds;
            await setGroupOptionsBurn(exists, exists.options?.deleteAfterSeconds, notify: true);
          }
          if (signature != exists.signature) {
            exists.setSignature(signature);
            await updateGroupData(groupId, exists.data, notify: true);
          }
        }
        if ((version != exists.version) || (count != exists.count)) {
          exists.version = version;
          exists.count = count;
          await updateGroupVersionCount(groupId, version, count, notify: true);
        }
        logger.i('$TAG - updatePrivateGroupOptions - group modify - group:$exists');
      } else {
        logger.d('$TAG - updatePrivateGroupOptions - group version same - remote_version:$version - exists:$exists');
      }
    }
    return exists;
  }

  Future<bool> pushPrivateGroupMembers(String? target, String? groupId, String? remoteVersion, {bool force = false}) async {
    if (target == null || target.isEmpty) return false;
    if (groupId == null || groupId.isEmpty) return false;
    // group
    PrivateGroupSchema? privateGroup = await queryGroup(groupId);
    if (privateGroup == null) return false;
    // version
    if (!force && (remoteVersion != null) && remoteVersion.isNotEmpty) {
      int commits = getPrivateGroupVersionCommits(privateGroup.version) ?? 0;
      List<String> memberKeys = getInviteesKey(await privateGroupCommon.getMembersAll(groupId));
      String nativeVersion = genPrivateGroupVersion(commits, privateGroup.signature, memberKeys);
      if (nativeVersion == remoteVersion) {
        logger.d('$TAG - pushPrivateGroupOptions - version same - version:$remoteVersion');
        return false;
      }
    }
    // item
    PrivateGroupItemSchema? privateGroupItem = await queryGroupItem(groupId, target);
    if (privateGroupItem == null) {
      logger.e('$TAG - pushPrivateGroupMembers - request is not in group.');
      return false;
    } else if ((privateGroupItem.permission ?? 0) <= PrivateGroupItemPerm.none) {
      chatOutCommon.sendPrivateGroupMemberResponse(target, privateGroup, [privateGroupItem]); // await
      return true;
    }
    // send
    List<PrivateGroupItemSchema> members = await getMembersAll(groupId, all: true);
    for (int i = 0; i < members.length; i += 10) {
      List<PrivateGroupItemSchema> memberSplits = members.skip(i).take(10).toList();
      chatOutCommon.sendPrivateGroupMemberResponse(target, privateGroup, memberSplits); // await
    }
    return true;
  }

  Future<PrivateGroupSchema?> updatePrivateGroupMembers(String? selfAddress, String? sender, String? groupId, String? remoteVersion, List<PrivateGroupItemSchema>? modifyMembers) async {
    if (sender == null || sender.isEmpty) return null;
    if (groupId == null || groupId.isEmpty) return null;
    if (remoteVersion == null || remoteVersion.isEmpty) return null;
    if (modifyMembers == null || modifyMembers.isEmpty) return null;
    // exists
    PrivateGroupSchema? schemaGroup = await queryGroup(groupId);
    if (schemaGroup == null) {
      logger.e('$TAG - updatePrivateGroupMembers - has no group. - groupId:$groupId');
      return null;
    }
    // version (can not gen version because members just not all, just check commits(version))
    int commits = getPrivateGroupVersionCommits(schemaGroup.version) ?? 0;
    List<String> memberKeys = getInviteesKey(await privateGroupCommon.getMembersAll(groupId));
    String nativeVersion = genPrivateGroupVersion(commits, schemaGroup.signature, memberKeys);
    String? nativeVersionNoCommits = getPrivateGroupVersionNoCommits(nativeVersion);
    String? remoteVersionNoCommits = getPrivateGroupVersionNoCommits(remoteVersion);
    if ((nativeVersionNoCommits != null) && (nativeVersionNoCommits.isNotEmpty) && (nativeVersionNoCommits == remoteVersionNoCommits)) {
      logger.d('$TAG - updatePrivateGroupMembers - members_keys version same. - remote_version:$remoteVersion - exists:$schemaGroup');
      return null;
    }
    // sender (can not believe sender perm because native members maybe empty)
    PrivateGroupItemSchema? groupItem = await queryGroupItem(groupId, sender);
    if (groupItem == null) {
      if (isOwner(schemaGroup.ownerPublicKey, sender)) {
        // nothing
      } else {
        logger.w('$TAG - updatePrivateGroupMembers - sender no owner. - group:$schemaGroup - item:$groupItem');
        return null;
      }
    } else if (isOwner(schemaGroup.ownerPublicKey, selfAddress)) {
      logger.d('$TAG - updatePrivateGroupMembers - self is owner. - group:$schemaGroup - item:$groupItem');
      return null;
    } else if ((groupItem.permission ?? 0) <= PrivateGroupItemPerm.none) {
      logger.w('$TAG - updatePrivateGroupMembers - sender no permission. - group:$schemaGroup - item:$groupItem');
      return null;
    }
    // members
    int selfJoined = 0;
    for (int i = 0; i < modifyMembers.length; i++) {
      PrivateGroupItemSchema member = modifyMembers[i];
      if (member.groupId != groupId) {
        logger.e('$TAG - updatePrivateGroupMembers - groupId incomplete data. - i$i - member:$member');
        continue;
      }
      if ((member.permission ?? 0) > PrivateGroupItemPerm.none) {
        if ((member.invitee == null) || (member.invitee?.isEmpty == true) || (member.inviter == null) || (member.inviter?.isEmpty == true) || (member.inviterRawData == null) || (member.inviterRawData?.isEmpty == true) || (member.inviteeRawData == null) || (member.inviteeRawData?.isEmpty == true) || (member.inviterSignature == null) || (member.inviterSignature?.isEmpty == true) || (member.inviteeSignature == null) || (member.inviteeSignature?.isEmpty == true)) {
          logger.e('$TAG - updatePrivateGroupMembers - inviter incomplete data - i$i - member:$member');
          continue;
        }
        bool verifiedInviter = await verifiedSignature(member.inviter, member.inviterRawData, member.inviterSignature);
        bool verifiedInvitee = await verifiedSignature(member.invitee, member.inviteeRawData, member.inviteeSignature);
        if (!verifiedInviter || !verifiedInvitee) {
          logger.e('$TAG - updatePrivateGroupMembers - signature verification failed. - verifiedInviter:$verifiedInviter - verifiedInvitee:$verifiedInvitee');
          continue;
        }
      } else {
        if ((member.invitee == null) || (member.invitee?.isEmpty == true) || (member.inviter == null) || (member.inviter?.isEmpty == true) || (member.inviterRawData == null) || (member.inviterRawData?.isEmpty == true) || (member.inviterSignature == null) || (member.inviterSignature?.isEmpty == true)) {
          logger.e('$TAG - updatePrivateGroupMembers - inviter incomplete data - i$i - member:$member');
          continue;
        }
        bool verifiedInviter = await verifiedSignature(member.inviter, member.inviterRawData, member.inviterSignature);
        if (!verifiedInviter) {
          logger.e('$TAG - updatePrivateGroupMembers - signature verification failed. - verifiedInviter:$verifiedInviter');
          continue;
        }
      }
      PrivateGroupItemSchema? exists = await queryGroupItem(groupId, member.invitee);
      if (exists == null) {
        exists = await addPrivateGroupItem(member, true, notify: true, checkDuplicated: false);
        logger.i('$TAG - updatePrivateGroupMembers - add item - i$i - member:$exists');
      } else if (exists.permission != member.permission) {
        bool success = await updateGroupItemPermission(member, true, notify: true);
        if (success) exists.permission = member.permission;
      }
      if ((member.invitee?.isNotEmpty == true) && (member.invitee == selfAddress)) {
        selfJoined = ((member.permission ?? 0) <= PrivateGroupItemPerm.none) ? -1 : 1;
      }
    }
    // joined
    if (!schemaGroup.joined && (selfJoined == 1)) {
      schemaGroup.joined = true;
      bool success = await updateGroupJoined(groupId, true, notify: true);
      if (!success) schemaGroup.joined = false;
    } else if (schemaGroup.joined && selfJoined == -1) {
      schemaGroup.joined = false;
      bool success = await updateGroupJoined(groupId, false, notify: true);
      if (!success) schemaGroup.joined = true;
    }
    return schemaGroup;
  }

  ///****************************************** Common *******************************************

  String getOwnerPublicKey(String groupId) {
    String owner;
    int index = groupId.lastIndexOf('.');
    owner = groupId.substring(0, index);
    return owner;
  }

  bool isOwner(String? ownerAddress, String? itemAddress) {
    if (ownerAddress == null || ownerAddress.isEmpty) return false;
    if (itemAddress == null || itemAddress.isEmpty) return false;
    String? ownerPubKey = getPubKeyFromTopicOrChatId(ownerAddress);
    String? itemPubKey = getPubKeyFromTopicOrChatId(itemAddress);
    return (ownerPubKey?.isNotEmpty == true) && (ownerPubKey == itemPubKey);
  }

  bool isAdmin(PrivateGroupSchema? group, PrivateGroupItemSchema? item) {
    if (group == null) return false;
    if (item == null) return false;
    if (group.type == PrivateGroupType.normal) {
      return (item.permission == PrivateGroupItemPerm.owner) || (item.permission == PrivateGroupItemPerm.admin);
    }
    return false;
  }

  Future<String?> genSignature(Uint8List? privateKey, String? rawData) async {
    if (privateKey == null || rawData == null || rawData.isEmpty) return null;
    Uint8List signRawData = Uint8List.fromList(Hash.sha256(rawData));
    Uint8List signData = await Crypto.sign(privateKey, signRawData);
    return hexEncode(signData);
  }

  Future<bool> verifiedSignature(String? publicKey, String? rawData, String? signature) async {
    if (publicKey == null || publicKey.isEmpty) return false;
    if (rawData == null || rawData.isEmpty) return false;
    if (signature == null || signature.isEmpty) return false;
    try {
      Uint8List pubKey = hexDecode(publicKey);
      Uint8List data = Uint8List.fromList(Hash.sha256(rawData));
      Uint8List sign = hexDecode(signature);
      return await Crypto.verify(pubKey, data, sign);
    } catch (e) {
      return false;
    }
  }

  String genPrivateGroupVersion(int commits, String optionSignature, List<String> memberKeys) {
    memberKeys.sort((a, b) => a.compareTo(b));
    return "$commits.${hexEncode(Uint8List.fromList(Hash.md5(optionSignature + memberKeys.join(''))))}";
  }

  int? getPrivateGroupVersionCommits(String? version) {
    if (version == null || version.isEmpty) return null;
    List<String> splits = version.split(".");
    if (splits.length < 2) return null;
    int? commits = int.tryParse(splits[0]);
    return commits ?? null;
  }

  String? getPrivateGroupVersionNoCommits(String? version) {
    if (version == null || version.isEmpty) return null;
    List<String> splits = version.split(".");
    if (splits.length < 2) return null;
    splits.removeAt(0);
    return splits.join();
  }

  /*String? increasePrivateGroupVersion(String? version) {
    if (version == null || version.isEmpty) return null;
    List<String> splits = version.split(".");
    if (splits.length < 2) return null;
    int? commits = int.tryParse(splits[0]);
    if (commits == null) return null;
    splits[0] = (commits + 1).toString() + ".";
    return splits.join();
  }*/

  Future<bool?> verifiedGroupVersion(PrivateGroupSchema? privateGroup, String? checkedVersion, {bool skipCommits = false}) async {
    if (privateGroup == null) return null;
    if (checkedVersion == null || checkedVersion.isEmpty) return false;
    String? nativeVersion = privateGroup.version;
    if (nativeVersion == null || nativeVersion.isEmpty) return false;
    if (!skipCommits) return checkedVersion == nativeVersion;
    String? checkedVersionNoCommits = getPrivateGroupVersionNoCommits(checkedVersion);
    String? nativeVersionNoCommits = getPrivateGroupVersionNoCommits(nativeVersion);
    if (checkedVersionNoCommits == null || checkedVersionNoCommits.isEmpty) return false;
    if (nativeVersionNoCommits == null || nativeVersionNoCommits.isEmpty) return false;
    return checkedVersionNoCommits == nativeVersionNoCommits;
  }

  List<String> getInviteesKey(List<PrivateGroupItemSchema> list) {
    List<String> ids = list.map((e) => (e.invitee?.isNotEmpty == true) ? "${e.permission}_${e.invitee}" : "").toList();
    ids.removeWhere((element) => element.isEmpty == true);
    ids.sort((a, b) => (a).compareTo(b));
    return ids;
  }

  List<Map<String, dynamic>> getMembersData(List<PrivateGroupItemSchema> list) {
    list.removeWhere((element) => element.invitee?.isEmpty == true);
    list.sort((a, b) => (a.invitee ?? "").compareTo(b.invitee ?? ""));
    List<Map<String, dynamic>> members = List.empty(growable: true);
    list.forEach((e) => members.add(e.toMap()
      ..remove('id')
      ..remove('data')));
    return members;
  }

  ///****************************************** Storage *******************************************

  Future<PrivateGroupSchema?> addPrivateGroup(PrivateGroupSchema? schema, bool sessionNotify, {bool notify = false, bool checkDuplicated = true}) async {
    if (schema == null || schema.groupId.isEmpty) return null;
    if (checkDuplicated) {
      PrivateGroupSchema? exist = await queryGroup(schema.groupId);
      if (exist != null) {
        logger.i("$TAG - addPrivateGroup - duplicated - schema:$exist");
        return null;
      }
    }
    PrivateGroupSchema? added = await PrivateGroupStorage.instance.insert(schema);
    if (added != null && notify) _addGroupSink.add(added);
    // session
    if (sessionNotify) await sessionCommon.set(schema.groupId, SessionType.PRIVATE_GROUP, notify: true);
    return added;
  }

  Future<bool> updateGroupNameType(String? groupId, String? name, int? type, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    bool success = await PrivateGroupStorage.instance.updateNameType(groupId, name, type);
    if (success && notify) queryAndNotifyGroup(groupId);
    return success;
  }

  Future<bool> updateGroupJoined(String? groupId, bool joined, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    bool success = await PrivateGroupStorage.instance.updateJoined(groupId, joined);
    if (success && notify) queryAndNotifyGroup(groupId);
    return success;
  }

  Future<bool> updateGroupVersionCount(String? groupId, String? version, int userCount, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    bool success = await PrivateGroupStorage.instance.updateVersionCount(groupId, version, userCount);
    if (success && notify) queryAndNotifyGroup(groupId);
    return success;
  }

  Future<bool> updateGroupAvatar(String? groupId, String? avatarLocalPath, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    bool success = await PrivateGroupStorage.instance.updateAvatar(groupId, avatarLocalPath);
    if (success && notify) queryAndNotifyGroup(groupId);
    return success;
  }

  Future<bool> setGroupOptionsBurn(PrivateGroupSchema? schema, int? burningSeconds, {bool notify = false}) async {
    if (schema == null || schema.id == null || schema.id == 0) return false;
    OptionsSchema options = schema.options ?? OptionsSchema();
    options.deleteAfterSeconds = burningSeconds ?? 0; // no options.updateBurnAfterAt
    bool success = await PrivateGroupStorage.instance.updateOptions(schema.groupId, options.toMap());
    if (success && notify) queryAndNotifyGroup(schema.groupId);
    return success;
  }

  Future<bool> updateGroupData(String? groupId, Map<String, dynamic>? data, {bool notify = false}) async {
    if (groupId == null || groupId.isEmpty) return false;
    bool success = await PrivateGroupStorage.instance.updateData(groupId, data);
    if (success && notify) queryAndNotifyGroup(groupId);
    return success;
  }

  Future<PrivateGroupSchema?> queryGroup(String? groupId) async {
    return await PrivateGroupStorage.instance.query(groupId);
  }

  Future<List<PrivateGroupSchema>> queryGroupListJoined({int? type, String? orderBy, int offset = 0, int limit = 20}) {
    return PrivateGroupStorage.instance.queryListJoined(type: type, orderBy: orderBy, offset: offset, limit: limit);
  }

  Future<PrivateGroupItemSchema?> addPrivateGroupItem(PrivateGroupItemSchema? schema, bool sessionNotify, {bool notify = false, bool checkDuplicated = true}) async {
    if (schema == null || schema.groupId.isEmpty) return null;
    if (checkDuplicated) {
      PrivateGroupItemSchema? exist = await queryGroupItem(schema.groupId, schema.invitee);
      if (exist != null) {
        logger.i("$TAG - addPrivateGroupItem - duplicated - schema:$exist");
        return null;
      }
    }
    PrivateGroupItemSchema? added = await PrivateGroupItemStorage.instance.insert(schema);
    if (added != null && notify) _addGroupItemSink.add(added);
    // session
    if (sessionNotify) {
      MessageSchema? message = MessageSchema.fromSend(
        msgId: Uuid().v4(),
        from: schema.invitee ?? "",
        groupId: schema.groupId,
        contentType: MessageContentType.privateGroupSubscribe,
        content: schema.invitee,
      );
      message.isOutbound = message.from == clientCommon.address;
      message.status = MessageStatus.Read;
      message.sendAt = DateTime.now().millisecondsSinceEpoch;
      message.receiveAt = DateTime.now().millisecondsSinceEpoch;
      message = await chatOutCommon.insertMessage(message, notify: true);
      if (message != null) await chatCommon.sessionHandle(message);
    }
    return added;
  }

  Future<PrivateGroupItemSchema?> queryGroupItem(String? groupId, String? invitee) async {
    return await PrivateGroupItemStorage.instance.queryByInvitee(groupId, invitee);
  }

  Future<List<PrivateGroupItemSchema>> queryMembers(String? groupId, {int? perm, int offset = 0, int limit = 20}) async {
    return await PrivateGroupItemStorage.instance.queryList(groupId, perm: perm, limit: limit, offset: offset);
  }

  Future<List<PrivateGroupItemSchema>> getMembersAll(String? groupId, {bool all = false}) async {
    if (groupId == null || groupId.isEmpty) return [];
    List<PrivateGroupItemSchema> members = [];
    int limit = 20;
    // owner
    List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.owner, offset: 0, limit: 1);
    members.addAll(result);
    // admin
    for (int offset = 0; true; offset += limit) {
      List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.admin, offset: offset, limit: limit);
      members.addAll(result);
      logger.d("$TAG - getMembersAll - admin - groupId:$groupId - offset:$offset - current_len:${result.length} - total_len:${members.length}");
      if (result.length < limit) break;
    }
    // normal
    for (int offset = 0; true; offset += limit) {
      List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.normal, offset: offset, limit: limit);
      members.addAll(result);
      logger.d("$TAG - getMembersAll - normal - groupId:$groupId - offset:$offset - current_len:${result.length} - total_len:${members.length}");
      if (result.length < limit) break;
    }
    // none
    if (all) {
      for (int offset = 0; true; offset += limit) {
        List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.none, offset: offset, limit: limit);
        members.addAll(result);
        logger.d("$TAG - getMembersAll - none - groupId:$groupId - offset:$offset - current_len:${result.length} - total_len:${members.length}");
        if (result.length < limit) break;
      }
    }
    // quit
    if (all) {
      for (int offset = 0; true; offset += limit) {
        List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.quit, offset: offset, limit: limit);
        members.addAll(result);
        logger.d("$TAG - getMembersAll - quit - groupId:$groupId - offset:$offset - current_len:${result.length} - total_len:${members.length}");
        if (result.length < limit) break;
      }
    }
    // black
    if (all) {
      for (int offset = 0; true; offset += limit) {
        List<PrivateGroupItemSchema> result = await queryMembers(groupId, perm: PrivateGroupItemPerm.black, offset: offset, limit: limit);
        members.addAll(result);
        logger.d("$TAG - getMembersAll - black - groupId:$groupId - offset:$offset - current_len:${result.length} - total_len:${members.length}");
        if (result.length < limit) break;
      }
    }
    return members;
  }

  Future<bool> updateGroupItemPermission(PrivateGroupItemSchema? item, bool sessionNotify, {bool notify = false}) async {
    if (item == null || item.groupId.isEmpty) return false;
    bool success = await PrivateGroupItemStorage.instance.updatePermission(
      item.groupId,
      item.invitee,
      item.permission,
      item.expiresAt,
      item.inviterRawData,
      item.inviteeRawData,
      item.inviterSignature,
      item.inviteeSignature,
    );
    if (success && notify) queryAndNotifyGroupItem(item.groupId, item.invitee);
    if (sessionNotify && (item.permission == PrivateGroupItemPerm.normal)) {
      MessageSchema? message = MessageSchema.fromSend(
        msgId: Uuid().v4(),
        from: item.invitee ?? "",
        groupId: item.groupId,
        contentType: MessageContentType.privateGroupSubscribe,
        content: item.invitee,
      );
      message.isOutbound = message.from == clientCommon.address;
      message.status = MessageStatus.Read;
      message.sendAt = DateTime.now().millisecondsSinceEpoch;
      message.receiveAt = DateTime.now().millisecondsSinceEpoch;
      message = await chatOutCommon.insertMessage(message, notify: true);
      if (message != null) await chatCommon.sessionHandle(message);
    }
    return success;
  }

  Future queryAndNotifyGroup(String? groupId) async {
    PrivateGroupSchema? updated = await PrivateGroupStorage.instance.query(groupId);
    if (updated != null) {
      _updateGroupSink.add(updated);
    }
  }

  Future queryAndNotifyGroupItem(String? groupId, String? invitee) async {
    PrivateGroupItemSchema? updated = await PrivateGroupItemStorage.instance.queryByInvitee(groupId, invitee);
    if (updated != null) {
      _updateGroupItemSink.add(updated);
    }
  }
}
