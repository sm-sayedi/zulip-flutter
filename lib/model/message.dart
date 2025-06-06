import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../api/model/events.dart';
import '../api/model/model.dart';
import '../api/route/messages.dart';
import '../log.dart';
import 'binding.dart';
import 'message_list.dart';
import 'store.dart';

const _apiSendMessage = sendMessage; // Bit ugly; for alternatives, see: https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/flutter.3A.20PerAccountStore.20methods/near/1545809

/// The portion of [PerAccountStore] for messages and message lists.
mixin MessageStore {
  /// All known messages, indexed by [Message.id].
  Map<int, Message> get messages;

  /// [OutboxMessage]s sent by the user, indexed by [OutboxMessage.localMessageId].
  Map<int, OutboxMessage> get outboxMessages;

  Set<MessageListView> get debugMessageListViews;

  void registerMessageList(MessageListView view);
  void unregisterMessageList(MessageListView view);

  Future<void> sendMessage({
    required MessageDestination destination,
    required String content,
  });

  /// Remove from [outboxMessages] given the [localMessageId], and return
  /// the removed [OutboxMessage].
  ///
  /// The outbox message to be taken must exist.
  ///
  /// The state of the outbox message must be either [OutboxMessageState.failed]
  /// or [OutboxMessageState.waitPeriodExpired].
  OutboxMessage takeOutboxMessage(int localMessageId);

  /// Reconcile a batch of just-fetched messages with the store,
  /// mutating the list.
  ///
  /// This is called after a [getMessages] request to report the result
  /// to the store.
  ///
  /// The list's length will not change, but some entries may be replaced
  /// by a different [Message] object with the same [Message.id].
  /// All [Message] objects in the resulting list will be present in
  /// [this.messages].
  void reconcileMessages(List<Message> messages);

  /// Whether the current edit request for the given message, if any, has failed.
  ///
  /// Will be null if there is no current edit request.
  /// Will be false if the current request hasn't failed
  /// and the update-message event hasn't arrived.
  bool? getEditMessageErrorStatus(int messageId);

  /// Edit a message's content, via a request to the server.
  ///
  /// Should only be called when there is no current edit request for [messageId],
  /// i.e., [getEditMessageErrorStatus] returns null for [messageId].
  ///
  /// See also:
  ///   * [getEditMessageErrorStatus]
  ///   * [takeFailedMessageEdit]
  void editMessage({
    required int messageId,
    required String originalRawContent,
    required String newContent,
  });

  /// Forgets the failed edit request and returns the attempted new content.
  ///
  /// Should only be called when there is a failed request,
  /// per [getEditMessageErrorStatus].
  ({String originalRawContent, String newContent}) takeFailedMessageEdit(int messageId);
}

class _EditMessageRequestStatus {
  _EditMessageRequestStatus({
    required this.hasError,
    required this.originalRawContent,
    required this.newContent,
  });

  bool hasError;
  final String originalRawContent;
  final String newContent;
}

class MessageStoreImpl extends PerAccountStoreBase with MessageStore, _OutboxMessageStore {
  MessageStoreImpl({required super.core, required String? realmEmptyTopicDisplayName})
    : _realmEmptyTopicDisplayName = realmEmptyTopicDisplayName,
      // There are no messages in InitialSnapshot, so we don't have
      // a use case for initializing MessageStore with nonempty [messages].
      messages = {};

  /// The display name to use for empty topics.
  ///
  /// This should only be accessed when FL >= 334, since topics cannot
  /// be empty otherwise.
  // TODO(server-10) simplify this
  String get realmEmptyTopicDisplayName {
    assert(zulipFeatureLevel >= 334);
    assert(_realmEmptyTopicDisplayName != null); // TODO(log)
    return _realmEmptyTopicDisplayName ?? 'general chat';
  }
  final String? _realmEmptyTopicDisplayName; // TODO(#668): update this realm setting

  @override
  final Map<int, Message> messages;

  @override
  final Set<MessageListView> _messageListViews = {};

  @override
  Set<MessageListView> get debugMessageListViews => _messageListViews;

  @override
  void registerMessageList(MessageListView view) {
    assert(!_disposed);
    final added = _messageListViews.add(view);
    assert(added);
  }

  @override
  void unregisterMessageList(MessageListView view) {
    // TODO: Add `assert(!_disposed);` here once we ensure [PerAccountStore] is
    //   only disposed after [MessageListView]s with references to it are
    //   disposed.  See [dispose] for details.
    final removed = _messageListViews.remove(view);
    assert(removed);
  }

  void _notifyMessageListViewsForOneMessage(int messageId) {
    for (final view in _messageListViews) {
      view.notifyListenersIfMessagePresent(messageId);
    }
  }

  void _notifyMessageListViews(Iterable<int> messageIds) {
    for (final view in _messageListViews) {
      view.notifyListenersIfAnyMessagePresent(messageIds);
    }
  }

  void reassemble() {
    for (final view in _messageListViews) {
      view.reassemble();
    }
  }

  @override
  bool _disposed = false;

  void dispose() {
    // Not disposing the [MessageListView]s here, because they are owned by
    // (i.e., they get [dispose]d by) the [_MessageListState], including in the
    // case where the [PerAccountStore] is replaced.
    //
    // TODO: Add assertions that the [MessageListView]s are indeed disposed, by
    //   first ensuring that [PerAccountStore] is only disposed after those with
    //   references to it are disposed, then reinstating this `dispose` method.
    //
    //   We can't add the assertions as-is because the sequence of events
    //   guarantees that `PerAccountStore` is disposed (when that happens,
    //   [GlobalStore] notifies its listeners, causing widgets dependent on the
    //   [InheritedNotifier] to rebuild in the next frame) before the owner's
    //   `dispose` or `onNewStore` is called.  Discussion:
    //     https://chat.zulip.org/#narrow/channel/243-mobile-team/topic/MessageListView.20lifecycle/near/2086893

    assert(!_disposed);
    _disposeOutboxMessages();
    _disposed = true;
  }

  @override
  Future<void> sendMessage({required MessageDestination destination, required String content}) {
    assert(!_disposed);
    if (!debugOutboxEnable) {
      return _apiSendMessage(connection,
        destination: destination,
        content: content,
        readBySender: true);
    }
    return _outboxSendMessage(
      destination: destination, content: content,
      // TODO move [TopicName.processLikeServer] to a substore, eliminating this
      //   see https://github.com/zulip/zulip-flutter/pull/1472#discussion_r2099069276
      realmEmptyTopicDisplayName: _realmEmptyTopicDisplayName);
  }

  @override
  void reconcileMessages(List<Message> messages) {
    assert(!_disposed);
    // What to do when some of the just-fetched messages are already known?
    // This is common and normal: in particular it happens when one message list
    // overlaps another, e.g. a stream and a topic within it.
    //
    // Most often, the just-fetched message will look just like the one we
    // already have.  But they can differ: message fetching happens out of band
    // from the event queue, so there's inherently a race.
    //
    // If the fetched message reflects changes we haven't yet heard from the
    // event queue, then it doesn't much matter which version we use: we'll
    // soon get the corresponding events and apply the changes anyway.
    // But if it lacks changes we've already heard from the event queue, then
    // we won't hear those events again; the only way to wind up with an
    // updated message is to use the version we have, that already reflects
    // those events' changes.  So we always stick with the version we have.
    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      messages[i] = this.messages.putIfAbsent(message.id, () => message);
    }
  }

  @override
  bool? getEditMessageErrorStatus(int messageId) =>
    _editMessageRequests[messageId]?.hasError;

  final Map<int, _EditMessageRequestStatus> _editMessageRequests = {};

  @override
  void editMessage({
    required int messageId,
    required String originalRawContent,
    required String newContent,
  }) async {
    assert(!_disposed);
    if (_editMessageRequests.containsKey(messageId)) {
      throw StateError('an edit request is already in progress');
    }

    _editMessageRequests[messageId] = _EditMessageRequestStatus(
      hasError: false, originalRawContent: originalRawContent, newContent: newContent);
    _notifyMessageListViewsForOneMessage(messageId);
    try {
      await updateMessage(connection,
        messageId: messageId,
        content: newContent,
        prevContentSha256: sha256.convert(utf8.encode(originalRawContent)).toString());
      // On success, we'll clear the status from _editMessageRequests
      // when we get the event.
    } catch (e) {
      // TODO(log) if e is something unexpected

      if (_disposed) return;

      final status = _editMessageRequests[messageId];
      if (status == null) {
        // The event actually arrived before this request failed
        // (can happen with network issues).
        // Or, the message was deleted.
        return;
      }
      status.hasError = true;
      _notifyMessageListViewsForOneMessage(messageId);
    }
  }

  @override
  ({String originalRawContent, String newContent}) takeFailedMessageEdit(int messageId) {
    assert(!_disposed);
    final status = _editMessageRequests.remove(messageId);
    _notifyMessageListViewsForOneMessage(messageId);
    if (status == null) {
      throw StateError('called takeFailedMessageEdit, but no edit');
    }
    if (!status.hasError) {
      throw StateError("called takeFailedMessageEdit, but edit hasn't failed");
    }
    return (
      originalRawContent: status.originalRawContent,
      newContent: status.newContent
    );
  }

  void handleUserTopicEvent(UserTopicEvent event) {
    for (final view in _messageListViews) {
      view.handleUserTopicEvent(event);
    }
  }

  void handleMessageEvent(MessageEvent event) {
    // If the message is one we already know about (from a fetch),
    // clobber it with the one from the event system.
    // See [fetchedMessages] for reasoning.
    messages[event.message.id] = event.message;

    _handleMessageEventOutbox(event);

    for (final view in _messageListViews) {
      view.handleMessageEvent(event);
    }
  }

  void handleUpdateMessageEvent(UpdateMessageEvent event) {
    assert(event.messageIds.contains(event.messageId), "See https://github.com/zulip/zulip-flutter/pull/753#discussion_r1649463633");
    _handleUpdateMessageEventTimestamp(event);
    _handleUpdateMessageEventContent(event);
    _handleUpdateMessageEventMove(event);
    _notifyMessageListViews(event.messageIds);
  }

  void _handleUpdateMessageEventTimestamp(UpdateMessageEvent event) {
    // TODO(server-5): Cut this fallback; rely on renderingOnly from FL 114
    final isRenderingOnly = event.renderingOnly ?? (event.userId == null);
    if (event.editTimestamp == null || isRenderingOnly) {
      // A rendering-only update gets omitted from the message edit history,
      // and [Message.lastEditTimestamp] is the last timestamp of that history.
      // So on a rendering-only update, the timestamp doesn't get updated.
      return;
    }

    for (final messageId in event.messageIds) {
      final message = messages[messageId];
      if (message == null) continue;
      message.lastEditTimestamp = event.editTimestamp;
    }
  }

  void _handleUpdateMessageEventContent(UpdateMessageEvent event) {
    final message = messages[event.messageId];
    if (message == null) return;

    message.flags = event.flags;
    if (event.origContent != null) {
      // The message is guaranteed to be edited.
      // See also: https://zulip.com/api/get-events#update_message
      message.editState = MessageEditState.edited;

      // Clear the edit-message progress feedback.
      // This makes a rare bug where we might clear the feedback too early,
      // if the user raced with themself to edit the same message
      // from multiple clients.
      _editMessageRequests.remove(message.id);
    }
    if (event.renderedContent != null) {
      assert(message.contentType == 'text/html',
        "Message contentType was ${message.contentType}; expected text/html.");
      message.content = event.renderedContent!;
    }
    if (event.isMeMessage != null) {
      message.isMeMessage = event.isMeMessage!;
    }

    for (final view in _messageListViews) {
      view.messageContentChanged(event.messageId);
    }
  }

  void _handleUpdateMessageEventMove(UpdateMessageEvent event) {
    final messageMove = event.moveData;
    if (messageMove == null) {
      // There was no move.
      return;
    }

    final UpdateMessageMoveData(
      :origStreamId, :newStreamId, :origTopic, :newTopic) = messageMove;

    final wasResolveOrUnresolve = newStreamId == origStreamId
      && MessageEditState.topicMoveWasResolveOrUnresolve(origTopic, newTopic);

    for (final messageId in event.messageIds) {
      final message = messages[messageId];
      if (message == null) continue;

      if (message is! StreamMessage) {
        assert(debugLog('Bad UpdateMessageEvent: stream/topic move on a DM')); // TODO(log)
        continue;
      }

      if (newStreamId != origStreamId) {
        message.conversation.streamId = newStreamId;
        // See [StreamConversation.displayRecipient] on why the invalidation is
        // needed.
        message.conversation.displayRecipient = null;
      }

      if (newTopic != origTopic) {
        message.conversation.topic = newTopic;
      }

      if (!wasResolveOrUnresolve
          && message.editState == MessageEditState.none) {
        message.editState = MessageEditState.moved;
      }
    }

    for (final view in _messageListViews) {
      view.messagesMoved(messageMove: messageMove, messageIds: event.messageIds);
    }
  }

  void handleDeleteMessageEvent(DeleteMessageEvent event) {
    for (final messageId in event.messageIds) {
      messages.remove(messageId);
      _editMessageRequests.remove(messageId);
    }
    for (final view in _messageListViews) {
      view.handleDeleteMessageEvent(event);
    }
  }

  void handleUpdateMessageFlagsEvent(UpdateMessageFlagsEvent event) {
    final isAdd = switch (event) {
      UpdateMessageFlagsAddEvent()    => true,
      UpdateMessageFlagsRemoveEvent() => false,
    };

    if (isAdd && (event as UpdateMessageFlagsAddEvent).all) {
      for (final message in messages.values) {
        message.flags.add(event.flag);
      }

      for (final view in _messageListViews) {
        if (view.messages.isEmpty) continue;
        view.notifyListeners();
      }
    } else {
      bool anyMessageFound = false;
      for (final messageId in event.messages) {
        final message = messages[messageId];
        if (message == null) continue; // a message we don't know about yet
        anyMessageFound = true;

        isAdd
          ? message.flags.add(event.flag)
          : message.flags.remove(event.flag);
      }
      if (anyMessageFound) {
        // TODO(#818): Support MentionsNarrow live-updates when handling
        //   @-mention flags.

        // To make it easier to re-star a message, we opt-out from supporting
        // live-updates when starred flag is removed.
        //
        // TODO: Support StarredMessagesNarrow live-updates when starred flag
        //   is added.
        _notifyMessageListViews(event.messages);
      }
    }
  }

  void handleReactionEvent(ReactionEvent event) {
    final message = messages[event.messageId];
    if (message == null) return;

    switch (event.op) {
      case ReactionOp.add:
        (message.reactions ??= Reactions([])).add(Reaction(
          emojiName: event.emojiName,
          emojiCode: event.emojiCode,
          reactionType: event.reactionType,
          userId: event.userId,
        ));
      case ReactionOp.remove:
        if (message.reactions == null) { // TODO(log)
          return;
        }
        message.reactions!.remove(
          reactionType: event.reactionType,
          emojiCode: event.emojiCode,
          userId: event.userId,
        );
    }
    _notifyMessageListViewsForOneMessage(event.messageId);
  }

  void handleSubmessageEvent(SubmessageEvent event) {
    final message = messages[event.messageId];
    if (message == null) return;

    final poll = message.poll;
    if (poll == null) {
      assert(debugLog('Missing poll for submessage event:\n${jsonEncode(event)}')); // TODO(log)
      return;
    }

    // Live-updates for polls should not rebuild the message lists.
    // [Poll] is responsible for notifying the affected listeners.
    poll.handleSubmessageEvent(event);
  }

  void handleMutedUsersEvent(MutedUsersEvent event) {
    for (final view in _messageListViews) {
      view.handleMutedUsersEvent(event);
    }
  }

  /// In debug mode, controls whether outbox messages should be created when
  /// [sendMessage] is called.
  ///
  /// Outside of debug mode, this is always true and the setter has no effect.
  static bool get debugOutboxEnable {
    bool result = true;
    assert(() {
      result = _debugOutboxEnable;
      return true;
    }());
    return result;
  }
  static bool _debugOutboxEnable = true;
  static set debugOutboxEnable(bool value) {
    assert(() {
      _debugOutboxEnable = value;
      return true;
    }());
  }

  @visibleForTesting
  static void debugReset() {
    _debugOutboxEnable = true;
  }
}

/// The duration an outbox message stays hidden to the user.
///
/// See [OutboxMessageState.waiting].
const kLocalEchoDebounceDuration = Duration(milliseconds: 500);  // TODO(#1441) find the right value for this

/// The duration before an outbox message can be restored for resending, since
/// its creation.
///
/// See [OutboxMessageState.waitPeriodExpired].
const kSendMessageOfferRestoreWaitPeriod = Duration(seconds: 10);  // TODO(#1441) find the right value for this

/// States of an [OutboxMessage] since its creation from a
/// [MessageStore.sendMessage] call and before its eventual deletion.
///
/// ```
///                             Got an [ApiRequestException].
///          ┌──────┬────────────────────────────┬──────────► failed
///          │      │                            │              │
///          │      │      [sendMessage]         │              │
/// (create) │      │      request succeeds.     │              │
///    └► hidden   waiting ◄─────────────── waitPeriodExpired ──┴─────► (delete)
///          │      ▲   │                     ▲               User restores
///          └──────┘   └─────────────────────┘               the draft.
///         Debounce     [sendMessage] request
///         timed out.   not finished when
///                      wait period timed out.
///
///              Event received.
/// (any state) ─────────────────► (delete)
/// ```
///
/// During its lifecycle, it is guaranteed that the outbox message is deleted
/// as soon a message event with a matching [MessageEvent.localMessageId]
/// arrives.
enum OutboxMessageState {
  /// The [sendMessage] HTTP request has started but the resulting
  /// [MessageEvent] hasn't arrived, and nor has the request failed.  In this
  /// state, the outbox message is hidden to the user.
  ///
  /// This is the initial state when an [OutboxMessage] is created.
  hidden,

  /// The [sendMessage] HTTP request has started but hasn't finished, and the
  /// outbox message is shown to the user.
  ///
  /// This state can be reached after staying in [hidden] for
  /// [kLocalEchoDebounceDuration], or when the request succeeds after the
  /// outbox message reaches [OutboxMessageState.waitPeriodExpired].
  waiting,

  /// The [sendMessage] HTTP request did not finish in time and the user is
  /// invited to retry it.
  ///
  /// This state can be reached when the request has not finished
  /// [kSendMessageOfferRestoreWaitPeriod] since the outbox message's creation.
  waitPeriodExpired,

  /// The message could not be delivered, and the user is invited to retry it.
  ///
  /// This state can be reached when we got an [ApiRequestException] from the
  /// [sendMessage] HTTP request.
  failed,
}

/// An outstanding request to send a message, aka an outbox-message.
///
/// This will be shown in the UI in the message list, as a placeholder
/// for the actual [Message] the request is anticipated to produce.
///
/// A request remains "outstanding" even after the [sendMessage] HTTP request
/// completes, whether with success or failure.
/// The outbox-message persists until either the corresponding [MessageEvent]
/// arrives to replace it, or the user discards it (perhaps to try again).
/// For details, see the state diagram at [OutboxMessageState],
/// and [MessageStore.takeOutboxMessage].
sealed class OutboxMessage<T extends Conversation> extends MessageBase<T> {
  OutboxMessage({
    required this.localMessageId,
    required int selfUserId,
    required super.timestamp,
    required this.contentMarkdown,
  }) : _state = OutboxMessageState.hidden,
       super(senderId: selfUserId);

  // TODO(dart): This has to be a plain static method, because factories/constructors
  //   do not support type parameters: https://github.com/dart-lang/language/issues/647
  static OutboxMessage fromConversation(Conversation conversation, {
    required int localMessageId,
    required int selfUserId,
    required int timestamp,
    required String contentMarkdown,
  }) {
    return switch (conversation) {
      StreamConversation() => StreamOutboxMessage._(
        localMessageId: localMessageId,
        selfUserId: selfUserId,
        timestamp: timestamp,
        conversation: conversation,
        contentMarkdown: contentMarkdown),
      DmConversation() => DmOutboxMessage._(
        localMessageId: localMessageId,
        selfUserId: selfUserId,
        timestamp: timestamp,
        conversation: conversation,
        contentMarkdown: contentMarkdown),
    };
  }

  /// As in [MessageEvent.localMessageId].
  ///
  /// This uniquely identifies this outbox message's corresponding message object
  /// in events from the same event queue.
  ///
  /// See also:
  ///  * [MessageStoreImpl.sendMessage], where this ID is assigned.
  final int localMessageId;

  @override
  int? get id => null;

  final String contentMarkdown;

  OutboxMessageState get state => _state;
  OutboxMessageState _state;

  /// Whether the [OutboxMessage] is hidden to [MessageListView] or not.
  bool get hidden => state == OutboxMessageState.hidden;
}

class StreamOutboxMessage extends OutboxMessage<StreamConversation> {
  StreamOutboxMessage._({
    required super.localMessageId,
    required super.selfUserId,
    required super.timestamp,
    required this.conversation,
    required super.contentMarkdown,
  });

  @override
  final StreamConversation conversation;
}

class DmOutboxMessage extends OutboxMessage<DmConversation> {
  DmOutboxMessage._({
    required super.localMessageId,
    required super.selfUserId,
    required super.timestamp,
    required this.conversation,
    required super.contentMarkdown,
  }) : assert(conversation.allRecipientIds.contains(selfUserId));

  @override
  final DmConversation conversation;
}

/// Manages the outbox messages portion of [MessageStore].
mixin _OutboxMessageStore on PerAccountStoreBase {
  late final UnmodifiableMapView<int, OutboxMessage> outboxMessages =
    UnmodifiableMapView(_outboxMessages);
  final Map<int, OutboxMessage> _outboxMessages = {};

  /// A map of timers to show outbox messages after a delay,
  /// indexed by [OutboxMessage.localMessageId].
  ///
  /// If the send message request fails within the time limit,
  /// the outbox message's timer gets removed and cancelled.
  final Map<int, Timer> _outboxMessageDebounceTimers = {};

  /// A map of timers to update outbox messages state to
  /// [OutboxMessageState.waitPeriodExpired] if the [sendMessage]
  /// request did not complete in time,
  /// indexed by [OutboxMessage.localMessageId].
  ///
  /// If the send message request completes within the time limit,
  /// the outbox message's timer gets removed and cancelled.
  final Map<int, Timer> _outboxMessageWaitPeriodTimers = {};

  /// A fresh ID to use for [OutboxMessage.localMessageId],
  /// unique within this instance.
  int _nextLocalMessageId = 1;

  /// As in [MessageStoreImpl._messageListViews].
  Set<MessageListView> get _messageListViews;

  /// As in [MessageStoreImpl._disposed].
  bool get _disposed;

  /// Update the state of the [OutboxMessage] with the given [localMessageId],
  /// and notify listeners if necessary.
  ///
  /// The outbox message with [localMessageId] must exist.
  void _updateOutboxMessage(int localMessageId, {
    required OutboxMessageState newState,
  }) {
    assert(!_disposed);
    final outboxMessage = outboxMessages[localMessageId];
    if (outboxMessage == null) {
      throw StateError(
        'Removing unknown outbox message with localMessageId: $localMessageId');
    }
    final oldState = outboxMessage.state;
    // See [OutboxMessageState] for valid state transitions.
    final isStateTransitionValid = switch (newState) {
      OutboxMessageState.hidden => false,
      OutboxMessageState.waiting =>
        oldState == OutboxMessageState.hidden
        || oldState == OutboxMessageState.waitPeriodExpired,
      OutboxMessageState.waitPeriodExpired =>
        oldState == OutboxMessageState.waiting,
      OutboxMessageState.failed =>
        oldState == OutboxMessageState.hidden
        || oldState == OutboxMessageState.waiting
        || oldState == OutboxMessageState.waitPeriodExpired,
    };
    if (!isStateTransitionValid) {
      throw StateError('Unexpected state transition: $oldState -> $newState');
    }

    outboxMessage._state = newState;
    for (final view in _messageListViews) {
      if (oldState == OutboxMessageState.hidden) {
        view.addOutboxMessage(outboxMessage);
      } else {
        view.notifyListenersIfOutboxMessagePresent(localMessageId);
      }
    }
  }

  /// Send a message and create an entry of [OutboxMessage].
  Future<void> _outboxSendMessage({
    required MessageDestination destination,
    required String content,
    required String? realmEmptyTopicDisplayName,
  }) async {
    assert(!_disposed);
    final localMessageId = _nextLocalMessageId++;
    assert(!outboxMessages.containsKey(localMessageId));

    final conversation = switch (destination) {
      StreamDestination(:final streamId, :final topic) =>
        StreamConversation(
          streamId,
          _processTopicLikeServer(
            topic, realmEmptyTopicDisplayName: realmEmptyTopicDisplayName),
          displayRecipient: null),
      DmDestination(:final userIds) => DmConversation(allRecipientIds: userIds),
    };

    _outboxMessages[localMessageId] = OutboxMessage.fromConversation(
      conversation,
      localMessageId: localMessageId,
      selfUserId: selfUserId,
      timestamp: ZulipBinding.instance.utcNow().millisecondsSinceEpoch ~/ 1000,
      contentMarkdown: content);

    _outboxMessageDebounceTimers[localMessageId] = Timer(
      kLocalEchoDebounceDuration,
      () => _handleOutboxDebounce(localMessageId));

    _outboxMessageWaitPeriodTimers[localMessageId] = Timer(
      kSendMessageOfferRestoreWaitPeriod,
      () => _handleOutboxWaitPeriodExpired(localMessageId));

    try {
      await _apiSendMessage(connection,
        destination: destination,
        content: content,
        readBySender: true,
        queueId: queueId,
        localId: localMessageId.toString());
    } catch (e) {
      if (_disposed) return;
      if (!_outboxMessages.containsKey(localMessageId)) {
        // The message event already arrived; the failure is probably due to
        // networking issues. Don't rethrow; the send succeeded
        // (we got the event) so we don't want to show an error dialog.
        return;
      }
      _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
      _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
      _updateOutboxMessage(localMessageId, newState: OutboxMessageState.failed);
      rethrow;
    }
    if (_disposed) return;
    if (!_outboxMessages.containsKey(localMessageId)) {
      // The message event already arrived; nothing to do.
      return;
    }
    // The send request succeeded, so the message was definitely sent.
    // Cancel the timer that would have had us start presuming that the
    // send might have failed.
    _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    if (_outboxMessages[localMessageId]!.state
          == OutboxMessageState.waitPeriodExpired) {
      // The user was offered to restore the message since the request did not
      // complete for a while.  Since the request was successful, we expect the
      // message event to arrive eventually.  Stop inviting the the user to
      // retry, to avoid double-sends.
      _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waiting);
    }
  }

  TopicName _processTopicLikeServer(TopicName topic, {
    required String? realmEmptyTopicDisplayName,
  }) {
    return topic.processLikeServer(
      // Processing this just once on creating the outbox message
      // allows an uncommon bug, because either of these values can change.
      // During the outbox message's life, a topic processed from
      // "(no topic)" could become stale/wrong when zulipFeatureLevel
      // changes; a topic processed from "general chat" could become
      // stale/wrong when realmEmptyTopicDisplayName changes.
      //
      // Shrug. The same effect is caused by an unavoidable race:
      // an admin could change the name of "general chat"
      // (i.e. the value of realmEmptyTopicDisplayName)
      // concurrently with the user making the send request,
      // so that the setting in effect by the time the request arrives
      // is different from the setting the client last heard about.
      zulipFeatureLevel: zulipFeatureLevel,
      realmEmptyTopicDisplayName: realmEmptyTopicDisplayName);
  }

  void _handleOutboxDebounce(int localMessageId) {
    assert(!_disposed);
    assert(outboxMessages.containsKey(localMessageId),
      'The timer should have been canceled when the outbox message was removed.');
    _outboxMessageDebounceTimers.remove(localMessageId);
    _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waiting);
  }

  void _handleOutboxWaitPeriodExpired(int localMessageId) {
    assert(!_disposed);
    assert(outboxMessages.containsKey(localMessageId),
      'The timer should have been canceled when the outbox message was removed.');
    assert(!_outboxMessageDebounceTimers.containsKey(localMessageId),
      'The debounce timer should have been removed before the wait period timer expires.');
    _outboxMessageWaitPeriodTimers.remove(localMessageId);
    _updateOutboxMessage(localMessageId, newState: OutboxMessageState.waitPeriodExpired);
  }

  OutboxMessage takeOutboxMessage(int localMessageId) {
    assert(!_disposed);
    final removed = _outboxMessages.remove(localMessageId);
    _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
    _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    if (removed == null) {
      throw StateError(
        'Removing unknown outbox message with localMessageId: $localMessageId');
    }
    if (removed.state != OutboxMessageState.failed
        && removed.state != OutboxMessageState.waitPeriodExpired
    ) {
      throw StateError('Unexpected state when restoring draft: ${removed.state}');
    }
    for (final view in _messageListViews) {
      view.removeOutboxMessage(removed);
    }
    return removed;
  }

  void _handleMessageEventOutbox(MessageEvent event) {
    if (event.localMessageId != null) {
      final localMessageId = int.parse(event.localMessageId!, radix: 10);
      // The outbox message can be missing if the user removes it (to be
      // implemented in #1441) before the event arrives.
      // Nothing to do in that case.
      _outboxMessages.remove(localMessageId);
      _outboxMessageDebounceTimers.remove(localMessageId)?.cancel();
      _outboxMessageWaitPeriodTimers.remove(localMessageId)?.cancel();
    }
  }

  /// Cancel [_OutboxMessageStore]'s timers.
  void _disposeOutboxMessages() {
    assert(!_disposed);
    for (final timer in _outboxMessageDebounceTimers.values) {
      timer.cancel();
    }
    for (final timer in _outboxMessageWaitPeriodTimers.values) {
      timer.cancel();
    }
  }
}
