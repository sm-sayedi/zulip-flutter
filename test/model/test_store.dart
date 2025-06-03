import 'package:collection/collection.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/initial_snapshot.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/events.dart';
import 'package:zulip/api/route/realm.dart';
import 'package:zulip/model/database.dart';
import 'package:zulip/model/settings.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/notifications/receive.dart';
import 'package:zulip/widgets/store.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;

mixin _ApiConnectionsMixin on GlobalStore {
  final Map<
    ({Uri realmUrl, int? zulipFeatureLevel, String? email, String? apiKey}),
    FakeApiConnection
  > _apiConnections = {};

  /// Whether [apiConnection] should return a cached connection.
  ///
  /// If true, [apiConnection] will return a cached [FakeApiConnection]
  /// from a previous call, if it is still open ([FakeApiConnection.isOpen]).
  /// If there is a cached connection but it has been closed
  /// with [ApiConnection.close], that connection will be ignored in favor
  /// of returning (and saving for next time) a fresh connection after all.
  ///
  /// If false (the default), returns a fresh connection each time.
  ///
  /// Setting this to true is useful if a test needs to access the same
  /// [FakeApiConnection] that the code under test will get, so as to use
  /// [FakeApiConnection.prepare] or [FakeApiConnection.lastRequest].
  /// The behavior with `true` breaches the base method's contract slightly --
  /// the base method would return a fresh connection each time --
  /// but that breach is sometimes convenient for tests.
  bool useCachedApiConnections = false;

  void clearCachedApiConnections() {
    _apiConnections.clear();
  }

  /// Get or construct a [FakeApiConnection] with the given arguments.
  ///
  /// To access the same [FakeApiConnection] that the code under test will get,
  /// so as to use [FakeApiConnection.prepare] or [FakeApiConnection.lastRequest],
  /// see [useCachedApiConnections].
  @override
  FakeApiConnection apiConnection({
      required Uri realmUrl, required int? zulipFeatureLevel,
      String? email, String? apiKey}) {
    final key = (realmUrl: realmUrl, zulipFeatureLevel: zulipFeatureLevel,
      email: email, apiKey: apiKey);
    if (useCachedApiConnections) {
      final connection = _apiConnections[key];
      if (connection != null && connection.isOpen) {
        return connection;
      }
    }
    return (_apiConnections[key] = FakeApiConnection(
      realmUrl: realmUrl, zulipFeatureLevel: zulipFeatureLevel,
      email: email, apiKey: apiKey));
  }
}

class _TestGlobalStoreBackend implements GlobalStoreBackend {
  @override
  Future<void> doUpdateGlobalSettings(GlobalSettingsCompanion data) async {
    // Nothing to do.
  }

  @override
  Future<void> doSetBoolGlobalSetting(BoolGlobalSetting setting, bool? value) async {
    // Nothing to do.
  }
}

mixin _DatabaseMixin on GlobalStore {
  int _nextAccountId = 1;

  @override
  Future<Account> doInsertAccount(AccountsCompanion data) async {
    // Check for duplication is typically handled by the database but since
    // we're not using a real database, this needs to be handled here.
    // See [AppDatabase.createAccount].
    // TODO: Ensure that parallel account insertions do not bypass this check.
    if (accounts.any((account) =>
          data.realmUrl.value == account.realmUrl
          && (data.userId.value == account.userId
              || data.email.value == account.email))) {
      throw AccountAlreadyExistsException();
    }

    final accountId = data.id.present ? data.id.value : _nextAccountId++;
    return Account(
      id: accountId,
      realmUrl: data.realmUrl.value,
      userId: data.userId.value,
      email: data.email.value,
      apiKey: data.apiKey.value,
      zulipFeatureLevel: data.zulipFeatureLevel.value,
      zulipVersion: data.zulipVersion.value,
      zulipMergeBase: data.zulipMergeBase.value,
      ackedPushToken: data.ackedPushToken.value,
    );
  }

  @override
  Future<void> doUpdateAccount(int accountId, AccountsCompanion data) async {
    // Nothing to do.
  }

  /// Consume the log of calls made to [doRemoveAccount].
  List<int> takeDoRemoveAccountCalls() {
    final result = _doRemoveAccountCalls;
    _doRemoveAccountCalls = null;
    return result ?? [];
  }
  List<int>? _doRemoveAccountCalls;

  @override
  Future<void> doRemoveAccount(int accountId) async {
    (_doRemoveAccountCalls ??= []).add(accountId);
    await Future<void>.delayed(TestGlobalStore.removeAccountDuration);
    // Nothing else to do.
  }
}

/// A [GlobalStore] containing data provided by callers,
/// and that causes no database queries or network requests.
///
/// Tests can provide data to the store by calling [add].
///
/// The per-account stores will use [FakeApiConnection].
///
/// Unlike with [LiveGlobalStore] and the associated [UpdateMachine.load],
/// there is no automatic event-polling loop or other automated requests.
/// Tests can use [PerAccountStore.updateMachine] in order to invoke that logic
/// explicitly when desired.
///
/// See also:
///   * [TestZulipBinding.globalStore], which provides one of these.
///   * [UpdateMachineTestGlobalStore], which prepares per-account data
///     using [UpdateMachine.load] (like [LiveGlobalStore] does).
class TestGlobalStore extends GlobalStore with _ApiConnectionsMixin, _DatabaseMixin {
  TestGlobalStore({
    GlobalSettingsData? globalSettings,
    Map<BoolGlobalSetting, bool>? boolGlobalSettings,
    required super.accounts,
  }) : super(backend: _TestGlobalStoreBackend(),
         globalSettings: globalSettings ?? GlobalSettingsData(),
         boolGlobalSettings: boolGlobalSettings ?? {},
       );

  final Map<int, InitialSnapshot> _initialSnapshots = {};

  static const Duration removeAccountDuration = Duration(milliseconds: 1);

  /// Add an account and corresponding server data to the test data.
  ///
  /// The given account will be added to the store.
  /// The given initial snapshot will be used to initialize a corresponding
  /// [PerAccountStore] when [perAccount] is subsequently called for this
  /// account, in particular when a [PerAccountStoreWidget] is mounted.
  Future<void> add(Account account, InitialSnapshot initialSnapshot) async {
    assert(initialSnapshot.zulipVersion == account.zulipVersion);
    assert(initialSnapshot.zulipMergeBase == account.zulipMergeBase);
    assert(initialSnapshot.zulipFeatureLevel == account.zulipFeatureLevel);
    await insertAccount(account.toCompanion(false));
    assert(!_initialSnapshots.containsKey(account.id));
    _initialSnapshots[account.id] = initialSnapshot;
  }

  Duration? loadPerAccountDuration;
  Object? loadPerAccountException;

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId) async {
    if (loadPerAccountDuration != null) {
      await Future<void>.delayed(loadPerAccountDuration!);
    }
    if (loadPerAccountException != null) {
      throw loadPerAccountException!;
    }
    final initialSnapshot = _initialSnapshots[accountId]!;
    final store = PerAccountStore.fromInitialSnapshot(
      globalStore: this,
      accountId: accountId,
      initialSnapshot: initialSnapshot,
    );
    UpdateMachine.fromInitialSnapshot(
      store: store, initialSnapshot: initialSnapshot);
    return Future.value(store);
  }
}

/// A [GlobalStore] that causes no database queries,
/// and loads per-account data from API responses prepared by callers.
///
/// The per-account stores will use [FakeApiConnection].
///
/// Like [LiveGlobalStore] and unlike [TestGlobalStore],
/// account data is loaded via [UpdateMachine.load].
/// Callers can set [prepareRegisterQueueResponse]
/// to prepare a register-queue payload or an exception.
/// The implementation pauses the event-polling loop
/// to avoid being a nuisance and does a boring
/// [FakeApiConnection.prepare] for the register-token request.
///
/// See also:
///   * [TestGlobalStore], which prepares per-account data
///     without using [UpdateMachine.load].
class UpdateMachineTestGlobalStore extends GlobalStore with _ApiConnectionsMixin, _DatabaseMixin {
  UpdateMachineTestGlobalStore({
    GlobalSettingsData? globalSettings,
    Map<BoolGlobalSetting, bool>? boolGlobalSettings,
    required super.accounts,
  }) : super(backend: _TestGlobalStoreBackend(),
         globalSettings: globalSettings ?? GlobalSettingsData(),
         boolGlobalSettings: boolGlobalSettings ?? {},
       );

  // [doLoadPerAccount] depends on the cache to prepare the API responses.
  // Calling [clearCachedApiConnections] is permitted, though.
  @override bool get useCachedApiConnections => true;
  @override set useCachedApiConnections(bool value) =>
    throw UnsupportedError(
      'Setting UpdateMachineTestGlobalStore.useCachedApiConnections '
      'is not supported.');

  void Function(FakeApiConnection)? prepareRegisterQueueResponse;

  void _prepareRegisterQueueSuccess(FakeApiConnection connection) {
    connection.prepare(json: eg.initialSnapshot().toJson());
  }

  @override
  Future<PerAccountStore> doLoadPerAccount(int accountId) async {
    final account = getAccount(accountId);

    // UpdateMachine.load should pick up the connection
    // with the network-request responses that we've prepared.
    assert(useCachedApiConnections);

    final connection = apiConnectionFromAccount(account!) as FakeApiConnection;
    (prepareRegisterQueueResponse ?? _prepareRegisterQueueSuccess)(connection);
    connection
      ..prepare(json: GetEventsResult(events: [HeartbeatEvent(id: 2)], queueId: null).toJson())
      ..prepare(json: ServerEmojiData(codeToNames: {}).toJson());
    if (NotificationService.instance.token.value != null) {
      connection.prepare(json: {}); // register-token
    }
    final updateMachine = await UpdateMachine.load(this, accountId);
    updateMachine.debugPauseLoop();
    return updateMachine.store;
  }
}

extension PerAccountStoreTestExtension on PerAccountStore {
  Future<void> addUser(User user) async {
    await handleEvent(RealmUserAddEvent(id: 1, person: user));
  }

  Future<void> addUsers(Iterable<User> users) async {
    for (final user in users) {
      await addUser(user);
    }
  }

  Future<void> muteUser(int id) async {
    await handleEvent(eg.mutedUsersEvent([...mutedUsers, id]));
  }

  Future<void> muteUsers(List<int> ids) async {
    for (final id in ids) {
      await muteUser(id);
    }
  }

  Future<void> unmuteUser(int id) async {
    await handleEvent(eg.mutedUsersEvent(
      mutedUsers.whereNot((userId) => userId == id).toList()));
  }

  Future<void> addStream(ZulipStream stream) async {
    await addStreams([stream]);
  }

  Future<void> addStreams(List<ZulipStream> streams) async {
    await handleEvent(ChannelCreateEvent(id: 1, streams: streams));
  }

  Future<void> addSubscription(Subscription subscription) async {
    await addSubscriptions([subscription]);
  }

  Future<void> addSubscriptions(List<Subscription> subscriptions) async {
    await handleEvent(SubscriptionAddEvent(id: 1, subscriptions: subscriptions));
  }

  Future<void> addUserTopic(ZulipStream stream, String topic, UserTopicVisibilityPolicy visibilityPolicy) async {
    await handleEvent(eg.userTopicEvent(stream.streamId, topic, visibilityPolicy));
  }

  Future<void> addMessage(Message message) async {
    await handleEvent(eg.messageEvent(message));
  }

  Future<void> addMessages(Iterable<Message> messages) async {
    for (final message in messages) {
      await addMessage(message);
    }
  }
}
