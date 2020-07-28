// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'message_codec.dart';
import 'message_codecs.dart';
import 'system_channels.dart';

typedef _BucketVisitor = void Function(RestorationBucket bucket);

/// Manages the restoration data in the framework and synchronizes it with the
/// engine.
///
/// Restoration data can be serialized out and - at a later point in time - be
/// used to restore the application to the previous state described by the
/// serialized data. Mobile operating systems use the concept of state
/// restoration to provide the illusion that apps continue to run in the
/// background forever: after an app has been backgrounded, the user can always
/// return to it and find it in the same state. In practice, the operating
/// system may, however, terminate the app to free resources for other apps
/// running in the foreground. Before that happens, the app gets a chance to
/// serialize out its restoration data. When the user navigates back to the
/// backgrounded app, it is restarted and the serialized restoration data is
/// provided to it again. Ideally, the app will use that data to restore itself
/// to the same state it was in when the user backgrounded the app.
///
/// In Flutter, restoration data is organized in a tree of [RestorationBucket]s
/// which is rooted in the [rootBucket]. All information that the application
/// needs to restore its current state must be stored in a bucket in this
/// hierarchy. To store data in the hierarchy, entities (e.g. [Widget]s) must
/// claim ownership of a child bucket from a parent bucket (which may be the
/// [rootBucket] provided by this [RestorationManager]). The owner of a bucket
/// may store arbitrary values in the bucket as long as they can be serialized
/// with the [StandardMessageCodec]. The values are stored in the bucket under a
/// given restoration ID as key. A restoration ID is a [Sting] that must be
/// unique within a given bucket. To access the stored value again during state
/// restoration, the same restoration ID must be provided again. The owner of
/// the bucket may also make the bucket available to other entities so that they
/// can claim child buckets from it for their own restoration needs. Within a
/// bucket, child buckets are also identified by unique restoration IDs. The
/// restoration ID must be provided when claiming a child bucket.
///
/// When restoration data is provided to the [RestorationManager] (e.g. after
/// the application relaunched when foregrounded again), the bucket hierarchy
/// with all the data stored in it is restored. Entities can retrieve the data
/// again by using the same restoration IDs that they originally used to store
/// the data.
///
/// In addition to providing restoration data when the app is launched,
/// restoration data may also be provided to a running app to restore it to a
/// previous state (e.g. when the user hits the back/forward button in the web
/// browser). When this happens, the current bucket hierarchy is decommissioned
/// and replaced with the hierarchy deserialized from the newly provided
/// restoration data. Buckets in the old hierarchy notify their listeners when
/// they get decommissioned. In response to the notification, listeners must
/// stop using the old buckets. Owners of those buckets must dispose of them and
/// claim a new child as a replacement from a parent in the new bucket hierarchy
/// (that parent may be the updated [rootBucket]).
///
/// Same platforms restrict the size of the restoration data. Therefore, the
/// data stored in the buckets should be as small as possible while still
/// allowing the app to restore its current state from it. Data that can be
/// retrieved from other services (e.g. a database or a web server) should not
/// be included in the restoration data. Instead, a small identifier (e.g. a
/// UUID, database record number, or resource locator) should be stored that can
/// be used to retrieve the data again from its original source during state
/// restoration.
///
/// The [RestorationManager] sends a serialized version of the bucket hierarchy
/// over to the engine at the end of a frame in which the data in the hierarchy
/// or its shape has changed. The engine caches the data until the operating
/// system needs it. The application is responsible for keeping the data in the
/// bucket always up-to-date to reflect its current state.
///
/// ## Discussion
///
/// Due to Flutter's threading model and restrictions in the APIs of the
/// platforms Flutter runs on, restoration data must be stored in the buckets
/// proactively as described above. When the operating system asks for the
/// restoration data, it will do so on the platform thread expecting a
/// synchronous response. To avoid the risk of deadlocks, the platform thread
/// cannot block and call into the UI thread (where the dart code is running) to
/// retrieve the restoration data. For this reason, the [RestorationManager]
/// always sends the latest copy of the restoration data from the UI thread over
/// to the platform thread whenever it changes. That way, the restoration data
/// is always ready to go on the platform thread when the operating system needs
/// it.
///
/// See also:
///
///  * [ServicesBinding.restorationManager], which holds the singleton instance
///    of the [RestorationManager] for the currently running application.
///  * [RestorationBucket], which make up the restoration data hierarchy.
///  * [RestorationMixin], which uses [RestorationBucket]s behind the scenes
///    to make [State] objects of [StatefulWidget]s restorable.
class RestorationManager extends ChangeNotifier {
  /// The root of the [RestorationBucket] hierarchy containing the restoration
  /// data.
  ///
  /// Child buckets can be claimed from this bucket via
  /// [RestorationBucket.claimChild]. If the [RestorationManager] has been asked
  /// to restore the application to a previous state, these buckets will contain
  /// the previously stored data. Otherwise the root bucket (and all children
  /// claimed from it) will be empty.
  ///
  /// The [RestorationManager] informs its listeners (added via [addListener])
  /// when the value returned by this getter changes. This happens when new
  /// restoration data has been provided to the [RestorationManager] to restore
  /// the application to a different state. In response to the notification,
  /// listeners must stop using the old root bucket and obtain the new one via
  /// this getter ([rootBucket] will have been updated to return the new bucket
  /// just before the listeners are notified).
  ///
  /// The restoration data describing the current bucket hierarchy is retrieved
  /// asynchronously from the engine the first time the root bucket is accessed
  /// via this getter. After the data has been copied over from the engine, this
  /// getter will return a [SynchronousFuture], that immediately resolves to the
  /// root [RestorationBucket].
  ///
  /// The returned [Future] may resolve to null if state restoration is
  /// currently turned off.
  ///
  /// See also:
  ///
  ///  * [RootRestorationScope], which makes the root bucket available in the
  ///    [Widget] tree.
  Future<RestorationBucket> get rootBucket {
    if (!SystemChannels.restoration.checkMethodCallHandler(_methodHandler)) {
      SystemChannels.restoration.setMethodCallHandler(_methodHandler);
    }
    if (_rootBucketIsValid) {
      return SynchronousFuture<RestorationBucket>(_rootBucket);
    }
    if (_pendingRootBucket == null) {
      _pendingRootBucket = Completer<RestorationBucket>();
      _getRootBucketFromEngine();
    }
    return _pendingRootBucket.future;
  }
  RestorationBucket _rootBucket; // May be null to indicate that restoration is turned off.
  Completer<RestorationBucket> _pendingRootBucket;
  bool _rootBucketIsValid = false;

  Future<void> _getRootBucketFromEngine() async {
    final Map<dynamic, dynamic> config = await SystemChannels.restoration.invokeMethod<Map<dynamic, dynamic>>('get');
    if (_pendingRootBucket == null) {
      // The restoration data was obtained via other means (e.g. by calling
      // [handleRestorationDataUpdate] while the request to the engine was
      // outstanding. Ignore the engine's response.
      return;
    }
    assert(_rootBucket == null);
    _parseAndHandleRestorationUpdateFromEngine(config);
  }

  void _parseAndHandleRestorationUpdateFromEngine(Map<dynamic, dynamic> update) {
    handleRestorationUpdateFromEngine(
      enabled: update != null && update['enabled'] as bool,
      data: update == null ? null : update['data'] as Uint8List,
    );
  }

  /// Called by the [RestorationManager] on itself to parse the restoration
  /// information obtained from the engine.
  ///
  /// The `enabled` parameter indicates whether the engine wants to receive
  /// restoration data. When `enabled` is false, state restoration is turned
  /// off and the [rootBucket] is set to null. When `enabled` is true, the
  /// provided restoration `data` will be parsed into the [rootBucket]. If
  /// `data` is null, an empty [rootBucket] will be instantiated.
  ///
  /// When this method is called, the old [rootBucket] is decommissioned.
  ///
  /// Subclasses in test frameworks may call this method at any time to inject
  /// restoration data (obtained e.g. by overriding [sendToEngine]) into the
  /// [RestorationManager]. When the method is called before the [rootBucket] is
  /// accessed, [rootBucket] will complete synchronously the next time it is
  /// called.
  @protected
  void handleRestorationUpdateFromEngine({@required bool enabled, @required Uint8List data}) {
    assert(enabled != null);

    final RestorationBucket oldRoot = _rootBucket;

    _rootBucket = enabled
        ? RestorationBucket.root(manager: this, rawData: _decodeRestorationData(data))
        : null;
    _rootBucketIsValid = true;
    assert(_pendingRootBucket == null || !_pendingRootBucket.isCompleted);
    _pendingRootBucket?.complete(_rootBucket);
    _pendingRootBucket = null;

    if (_rootBucket != oldRoot) {
      notifyListeners();
    }
    if (oldRoot != null) {
      oldRoot
        ..decommission()
        ..dispose();
    }
  }

  /// Called by the [RestorationManager] on itself to send the provided
  /// encoded restoration data to the engine.
  ///
  /// The `encodedData` describes the entire bucket hierarchy that makes up the
  /// current restoration data.
  ///
  /// Subclasses in test frameworks may override this method to capture the
  /// restoration data that would have been send to the engine. The captured
  /// data can be re-injected into the [RestorationManager] via the
  /// [handleRestorationUpdateFromEngine] method to restore the state described
  /// by the data.
  @protected
  Future<void> sendToEngine(Uint8List encodedData) {
    assert(encodedData != null);
    return SystemChannels.restoration.invokeMethod<void>(
      'put',
      encodedData,
    );
  }

  Future<dynamic> _methodHandler(MethodCall call) {
    switch (call.method) {
      case 'push':
        _parseAndHandleRestorationUpdateFromEngine(call.arguments as Map<dynamic, dynamic>);
        break;
      default:
        throw UnimplementedError("${call.method} was invoked but isn't implemented by $runtimeType");
    }
    return null;
  }

  Map<dynamic, dynamic> _decodeRestorationData(Uint8List data) {
    if (data == null) {
      return null;
    }
    final ByteData encoded = data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes);
    return const StandardMessageCodec().decodeMessage(encoded) as Map<dynamic, dynamic>;
  }

  Uint8List _encodeRestorationData(Map<dynamic, dynamic> data) {
    final ByteData encoded = const StandardMessageCodec().encodeMessage(data);
    return encoded.buffer.asUint8List(encoded.offsetInBytes, encoded.lengthInBytes);
  }

  bool _debugDoingUpdate = false;
  bool _postFrameScheduled = false;

  final Set<RestorationBucket> _bucketsNeedingSerialization = <RestorationBucket>{};

  /// Called by a [RestorationBucket] to request serialization for that bucket.
  ///
  /// This method is called by a bucket in the hierarchy whenever the data
  /// in it or the shape of the hierarchy has changed.
  ///
  /// Calling this is a no-op when the bucket is already scheduled for
  /// serialization.
  ///
  /// It is exposed to allow testing of [RestorationBucket]s in isolation.
  @protected
  @visibleForTesting
  void scheduleSerializationFor(RestorationBucket bucket) {
    assert(bucket != null);
    assert(bucket._manager == this);
    assert(!_debugDoingUpdate);
    _bucketsNeedingSerialization.add(bucket);
    if (!_postFrameScheduled) {
      _postFrameScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((Duration _) => _doSerialization());
    }
  }

  /// Called by a [RestorationBucket] to unschedule a request for serialization.
  ///
  /// This method is called by a bucket in the hierarchy whenever it no longer
  /// needs to be serialized (e.g. because the bucket got disposed).
  ///
  /// It is safe to call this even when the bucket wasn't scheduled for
  /// serialization before.
  ///
  /// It is exposed to allow testing of [RestorationBucket]s in isolation.
  @protected
  @visibleForTesting
  void unscheduleSerializationFor(RestorationBucket bucket) {
    assert(bucket != null);
    assert(bucket._manager == this);
    assert(!_debugDoingUpdate);
    _bucketsNeedingSerialization.remove(bucket);
  }

  void _doSerialization() {
    assert(() {
      _debugDoingUpdate = true;
      return true;
    }());
    _postFrameScheduled = false;

    for (final RestorationBucket bucket in _bucketsNeedingSerialization) {
      bucket.finalize();
    }
    _bucketsNeedingSerialization.clear();
    sendToEngine(_encodeRestorationData(_rootBucket._rawData));

    assert(() {
      _debugDoingUpdate = false;
      return true;
    }());
  }
}

/// A [RestorationBucket] holds pieces of the restoration data that a part of
/// the application needs to restore its state.
///
/// For a general overview of how state restoration works in Flutter, see the
/// [RestorationManager].
///
/// [RestorationBucket]s are organized in a tree that is rooted in
/// [RestorationManager.rootBucket] and managed by a [RestorationManager]. The
/// tree is serializable and must contain all the data an application needs to
/// restore its current state at a later point in time.
///
/// A [RestorationBucket] stores restoration data as key-value pairs. The key is
/// a [String] representing a restoration ID that identifies a piece of data
/// uniquely within a bucket. The value can be anything that is serializable via
/// the [StandardMessageCodec]. Furthermore, a [RestorationBucket] may have
/// child buckets, which are identified within their parent via a unique
/// restoration ID as well.
///
/// During state restoration, the data previously stored in the
/// [RestorationBucket] hierarchy will be made available again to the
/// application to restore it to the state it had when the data was collected.
/// State restoration to a previous state may happen when the app is launched
/// (e.g. after it has been terminated gracefully while running in the
/// background) or after the app has already been running for a while.
///
/// ## Lifecycle
///
/// A [RestorationBucket] is rarely instantiated directly via its constructors.
/// Instead, when an entity wants to store data in or retrieve data from a
/// restoration bucket, it typically obtains a child bucket from a parent by
/// calling [claimChild]. If no parent is available,
/// [RestorationManager.rootBucket] may be used as a parent. When claiming a
/// child, the claimer must provide the restoration ID of the child it would
/// like to own. A child bucket with a given restoration ID can at most have
/// one owner. If another owner tries to claim a bucket with the same ID from
/// the same parent, an exception is thrown (see discussion in [claimChild]).
/// The restoration IDs that a given owner uses to claim a child (and to store
/// data in that child, see below) must be stable across app launches to ensure
/// that after the app restarts the owner can retrieve the same data again that
/// it stored during a previous run.
///
/// Per convention, the owner of the bucket has exclusive access to the values
/// stored in the bucket. It can read, add, modify, and remove values via the
/// [read], [write], and [remove] methods. In general, the owner should store
/// all the data in the bucket that it needs to restore its current state. If
/// its current state changes, the data in the bucket must be updated. At the
/// same time, the data in the bucket should be kept to a minimum. For example,
/// for data that can be retrieved from other sources (like a database or
/// webservice) only enough information (e.g. an ID or resource locator) to
/// re-obtain that data should be stored in the bucket. In addition to managing
/// the data in a bucket, an owner may also make the bucket available to other
/// entities so they can claim child buckets from it via [claimChild] for their
/// own restoration needs.
///
/// The bucket returned by [claimChild] may either contain state information
/// that the owner had previously (e.g. during a previous run of the
/// application) stored in it or it may be empty. If the bucket contains data,
/// the owner is expected to restore its state with the information previously
/// stored in the bucket. If the bucket is empty, it may initialize itself to
/// default values.
///
/// During the lifetime of a bucket, it may notify its listeners that the bucket
/// has been [decommission]ed. This happens when new restoration data has been
/// provided to, for example, the [RestorationManager] to restore the
/// application to a different state (e.g. when the user hits the back/forward
/// button in the web browser). In response to the notification, owners must
/// dispose their current bucket and replace it with a new bucket claimed from a
/// new parent (which will have been initialized with the new restoration data).
/// For example, if the owner previously claimed its bucket from
/// [RestorationManager.rootBucket], it must claim its new bucket from there
/// again. The root bucket will have been replaced with the new root bucket just
/// before the bucket listeners are informed about the decommission. Once the
/// new bucket is obtained, owners should restore their internal state according
/// to the information in the new bucket.
///
/// When the data stored in a bucket is no longer needed to restore the
/// application to its current state (e.g. because the owner of the bucket is no
/// longer shown on screen), the bucket must be [dispose]d. This will remove all
/// information stored in the bucket from the app's restoration data and that
/// information will not be available again when the application is restored to
/// this state in the future.
class RestorationBucket extends ChangeNotifier {
  /// Creates an empty [RestorationBucket] to be provided to [adoptChild] to add
  /// it to the bucket hierarchy.
  ///
  /// {@template flutter.services.restoration.bucketcreation}
  /// Instantiating a bucket directly is rare, most buckets are created by
  /// claiming a child from a parent via [claimChild]. If no parent bucket is
  /// available, [RestorationManager.rootBucket] may be used as a parent.
  /// {@endtemplate}
  ///
  /// The `restorationId` must not be null.
  RestorationBucket.empty({
    @required String restorationId,
    @required Object debugOwner,
  }) : assert(restorationId != null),
       _restorationId = restorationId,
       _rawData = <String, dynamic>{} {
    assert(() {
      _debugOwner = debugOwner;
      return true;
    }());
  }

  /// Creates the root [RestorationBucket] for the provided restoration
  /// `manager`.
  ///
  /// The `rawData` must either be null (in which case an empty bucket will be
  /// instantiated) or it must be a nested map describing the entire bucket
  /// hierarchy in the following format:
  ///
  /// ```javascript
  /// {
  ///  'v': {  // key-value pairs
  ///     // * key is a string representation a restoration ID
  ///     // * value is any primitive that can be encoded with [StandardMessageCodec]
  ///    '<restoration-id>: <Object>,
  ///   },
  ///  'c': {  // child buckets
  ///    'restoration-id': <nested map representing a child bucket>
  ///   }
  /// }
  /// ```
  ///
  /// {@macro flutter.services.restoration.bucketcreation}
  ///
  /// The `manager` argument must not be null.
  RestorationBucket.root({
    @required RestorationManager manager,
    @required Map<dynamic, dynamic> rawData,
  }) : assert(manager != null),
       _manager = manager,
       _rawData = rawData ?? <dynamic, dynamic>{},
       _restorationId = 'root' {
    assert(() {
      _debugOwner = manager;
      return true;
    }());
  }

  /// Creates a child bucket initialized with the data that the provided
  /// `parent` has stored under the provided [id].
  ///
  /// This constructor cannot be used if the `parent` does not have any child
  /// data stored under the given ID. In that case, create an empty bucket (via
  /// [RestorationBucket.empty] and have the parent adopt it via [adoptChild].
  ///
  /// {@macro flutter.services.restoration.bucketcreation}
  ///
  /// The `restorationId` and `parent` argument must not be null.
  RestorationBucket.child({
    @required String restorationId,
    @required RestorationBucket parent,
    @required Object debugOwner,
  }) : assert(restorationId != null),
       assert(parent != null),
       assert(parent._rawChildren[restorationId] != null),
       _manager = parent._manager,
       _parent = parent,
       _rawData = parent._rawChildren[restorationId] as Map<dynamic, dynamic>,
       _restorationId = restorationId {
    assert(() {
      _debugOwner = debugOwner;
      return true;
    }());
  }

  static const String _childrenMapKey = 'c';
  static const String _valuesMapKey = 'v';

  final Map<dynamic, dynamic> _rawData;

  /// The owner of the bucket that was provided when the bucket was claimed via
  /// [claimChild].
  ///
  /// The value is used in error messages. Accessing the value is only valid
  /// in debug mode, otherwise it will return null.
  Object get debugOwner {
    assert(_debugAssertNotDisposed());
    return _debugOwner;
  }
  Object _debugOwner;

  RestorationManager _manager;
  RestorationBucket _parent;

  /// The restoration ID under which the bucket is currently stored in the
  /// parent of this bucket (or wants to be stored if it is currently
  /// parent-less).
  ///
  /// This value is never null.
  String get restorationId {
    assert(_debugAssertNotDisposed());
    return _restorationId;
  }
  String _restorationId;

  // Maps a restoration ID to the raw map representation of a child bucket.
  Map<dynamic, dynamic> get _rawChildren => _rawData.putIfAbsent(_childrenMapKey, () => <dynamic, dynamic>{}) as Map<dynamic, dynamic>;
  // Maps a restoration ID to a value that is stored in this bucket.
  Map<dynamic, dynamic> get _rawValues => _rawData.putIfAbsent(_valuesMapKey, () => <dynamic, dynamic>{}) as Map<dynamic, dynamic>;

  /// Called to signal that this bucket and all its descendants are no longer
  /// part of the current restoration data and must not be used anymore.
  ///
  /// Calling this method will drop this bucket from its parent and notify all
  /// its listeners as well as all listeners of its descendants. Once a bucket
  /// has notified its listeners, it must not be used anymore. During the next
  /// frame following the notification, the bucket must be disposed and replaced
  /// with a new bucket.
  ///
  /// As an example, the [RestorationManager] calls this method on its root
  /// bucket when it has been asked to restore a running application to a
  /// different state. At that point, the data stored in the current bucket
  /// hierarchy is invalid and will be replaced with a new hierarchy generated
  /// from the restoration data describing the new state. To replace the current
  /// bucket hierarchy, [decommission] is called on the root bucket to signal to
  /// all owners of buckets in the hierarchy that their bucket has become
  /// invalid. In response to the notification, bucket owners must [dispose]
  /// their buckets and claim a new bucket from the newly created hierarchy. For
  /// example, the owner of a bucket that was originally claimed from the
  /// [RestorationManager.rootBucket] must dispose that bucket and claim a new
  /// bucket from the new [RestorationManager.rootBucket]. Once the new bucket
  /// is claimed, owners should restore their state according to the data stored
  /// in the new bucket.
  void decommission() {
    assert(_debugAssertNotDisposed());
    if (_parent != null) {
      _parent._dropChild(this);
      _parent = null;
    }
    _performDecommission();
  }

  bool _decommissioned = false;

  void _performDecommission() {
    _decommissioned = true;
    _updateManager(null);
    notifyListeners();
    _visitChildren((RestorationBucket bucket) {
      bucket._performDecommission();
    });
  }

  // Get and store values.

  /// Returns the value of type `P` that is currently stored in the bucket under
  /// the provided `restorationId`.
  ///
  /// Returns null if nothing is stored under that id. Throws, if the value
  /// stored under the ID is not of type `P`.
  ///
  /// See also:
  ///
  ///  * [write], which stores a value in the bucket.
  ///  * [remove], which removes a value from the bucket.
  ///  * [contains], which checks whether any value is stored under a given
  ///    restoration ID.
  P read<P>(String restorationId) {
    assert(_debugAssertNotDisposed());
    assert(restorationId != null);
    return _rawValues[restorationId] as P;
  }

  /// Stores the provided `value` of type `P` under the provided `restorationId`
  /// in the bucket.
  ///
  /// Any value that has previously been stored under that ID is overwritten
  /// with the new value. The provided `value` must be serializable with the
  /// [StandardMessageCodec].
  ///
  /// Null values will be stored in the bucket as-is. To remove a value, use
  /// [remove].
  ///
  /// See also:
  ///
  ///  * [read], which retrieves a stored value from the bucket.
  ///  * [remove], which removes a value from the bucket.
  ///  * [contains], which checks whether any value is stored under a given
  ///    restoration ID.
  void write<P>(String restorationId, P value) {
    assert(_debugAssertNotDisposed());
    assert(restorationId != null);
    assert(debugIsSerializableForRestoration(value));
    if (_rawValues[restorationId] != value || !_rawValues.containsKey(restorationId)) {
      _rawValues[restorationId] = value;
      _markNeedsSerialization();
    }
  }

  /// Deletes the value currently stored under the provided `restorationId` from
  /// the bucket.
  ///
  /// The value removed from the bucket is casted to `P` and returned. If no
  /// value was stored under that id, null is returned.
  ///
  /// See also:
  ///
  ///  * [read], which retrieves a stored value from the bucket.
  ///  * [write], which stores a value in the bucket.
  ///  * [contains], which checks whether any value is stored under a given
  ///    restoration ID.
  P remove<P>(String restorationId) {
    assert(_debugAssertNotDisposed());
    assert(restorationId != null);
    final bool needsUpdate = _rawValues.containsKey(restorationId);
    final P result = _rawValues.remove(restorationId) as P;
    if (_rawValues.isEmpty) {
      _rawData.remove(_valuesMapKey);
    }
    if (needsUpdate) {
      _markNeedsSerialization();
    }
    return result;
  }

  /// Checks whether a value stored in the bucket under the provided
  /// `restorationId`.
  ///
  /// See also:
  ///
  ///  * [read], which retrieves a stored value from the bucket.
  ///  * [write], which stores a value in the bucket.
  ///  * [remove], which removes a value from the bucket.
  bool contains(String restorationId) {
    assert(_debugAssertNotDisposed());
    assert(restorationId != null);
    return _rawValues.containsKey(restorationId);
  }

  // Child management.

  // The restoration IDs and associated buckets of children that have been
  // claimed via [claimChild].
  final Map<String, RestorationBucket> _claimedChildren = <String, RestorationBucket>{};
  // Newly created child buckets whose restoration ID is still in use, see
  // comment in [claimChild] for details.
  final Map<String, List<RestorationBucket>> _childrenToAdd = <String, List<RestorationBucket>>{};

  /// Claims ownership of the child with the provided `restorationId` from this
  /// bucket.
  ///
  /// If the application is getting restored to a previous state, the bucket
  /// will contain all the data that was previously stored in the bucket.
  /// Otherwise, an empty bucket is returned.
  ///
  /// The claimer of the bucket is expected to use the data stored in the bucket
  /// to restore itself to its previous state described by the data in the
  /// bucket. If the bucket is empty, it should initialize itself to default
  /// values. Whenever the information that the claimer needs to restore its
  /// state changes, the data in the bucket should be updated to reflect that.
  ///
  /// A child bucket with a given `restorationId` can only have one owner. If
  /// another owner claims a child bucket with the same `restorationId` an
  /// exception will be thrown at the end of the current frame unless the
  /// previous owner has either deleted its bucket by calling [dispose] or has
  /// moved it to a new parent via [adoptChild].
  ///
  /// When the returned bucket is no longer needed, it must be [dispose]d to
  /// delete the information stored in it from the app's restoration data.
  RestorationBucket claimChild(String restorationId, {@required Object debugOwner}) {
    assert(_debugAssertNotDisposed());
    assert(restorationId != null);
    // There are three cases to consider:
    // 1. Claiming an ID that has already been claimed.
    // 2. Claiming an ID that doesn't yet exist in [_rawChildren].
    // 3. Claiming an ID that does exist in [_rawChildren] and hasn't been
    //    claimed yet.
    // If an ID has already been claimed (case 1) the current owner may give up
    // that ID later this frame and it can be re-used. In anticipation of the
    // previous owner's surrender of the id, we return an empty bucket for this
    // new claim and check in [_debugAssertIntegrity] that at the end of the
    // frame the old owner actually did surrendered the id.
    // Case 2 also requires the creation of a new empty bucket.
    // In Case 3 we create a new bucket wrapping the existing data in
    // [_rawChildren].

    // Case 1+2: Adopt and return an empty bucket.
    if (_claimedChildren.containsKey(restorationId) || !_rawChildren.containsKey(restorationId)) {
      final RestorationBucket child = RestorationBucket.empty(
        debugOwner: debugOwner,
        restorationId: restorationId,
      );
      adoptChild(child);
      return child;
    }

    // Case 3: Return bucket wrapping the existing data.
    assert(_rawChildren[restorationId] != null);
    final RestorationBucket child = RestorationBucket.child(
      restorationId: restorationId,
      parent: this,
      debugOwner: debugOwner,
    );
    _claimedChildren[restorationId] = child;
    return child;
  }

  /// Adopts the provided `child` bucket.
  ///
  /// The `child` will be dropped from its old parent, if it had one.
  ///
  /// The `child` is stored under its [id] in this bucket. If this bucket
  /// already contains a child bucket under the same id, the owner of that
  /// existing bucket must give it up (e.g. by moving the child bucket to a
  /// different parent or by disposing it) before the end of the current frame.
  /// Otherwise an exception indicating the illegal use of duplicated
  /// restoration IDs will trigger in debug mode.
  ///
  /// No-op if the provided bucket is already a child of this bucket.
  void adoptChild(RestorationBucket child) {
    assert(_debugAssertNotDisposed());
    assert(child != null);
    if (child._parent != this) {
      child._parent?._removeChildData(child);
      child._parent = this;
      _addChildData(child);
      if (child._manager != _manager) {
        _recursivelyUpdateManager(child);
      }
    }
    assert(child._parent == this);
    assert(child._manager == _manager);
  }

  void _dropChild(RestorationBucket child) {
    assert(child != null);
    assert(child._parent == this);
    _removeChildData(child);
    child._parent = null;
    if (child._manager != null) {
      child._updateManager(null);
      child._visitChildren(_recursivelyUpdateManager);
    }
  }

  bool _needsSerialization = false;
  void _markNeedsSerialization() {
    assert(_manager != null || _decommissioned);
    if (!_needsSerialization) {
      _needsSerialization = true;
      _manager?.scheduleSerializationFor(this);
    }
  }

  /// Called by the [RestorationManager] just before the data of the bucket
  /// is serialized and send to the engine.
  ///
  /// It is exposed to allow testing of [RestorationBucket]s in isolation.
  @visibleForTesting
  void finalize() {
    assert(_debugAssertNotDisposed());
    assert(_needsSerialization);
    _needsSerialization = false;
    assert(_debugAssertIntegrity());
  }

  void _recursivelyUpdateManager(RestorationBucket bucket) {
    bucket._updateManager(_manager);
    bucket._visitChildren(_recursivelyUpdateManager);
  }

  void _updateManager(RestorationManager newManager) {
    if (_manager == newManager) {
      return;
    }
    if (_needsSerialization) {
      _manager?.unscheduleSerializationFor(this);
    }
    _manager = newManager;
    if (_needsSerialization && _manager != null) {
      _needsSerialization = false;
      _markNeedsSerialization();
    }
  }

  bool _debugAssertIntegrity() {
    assert(() {
      if (_childrenToAdd.isEmpty) {
        return true;
      }
      final List<DiagnosticsNode> error = <DiagnosticsNode>[
        ErrorSummary('Multiple owners claimed child RestorationBuckets with the same IDs.'),
        ErrorDescription('The following IDs were claimed multiple times from the parent $this:')
      ];
      for (final MapEntry<String, List<RestorationBucket>> child in _childrenToAdd.entries) {
        final String id = child.key;
        final List<RestorationBucket> buckets = child.value;
        assert(buckets.isNotEmpty);
        assert(_claimedChildren.containsKey(id));
        error.addAll(<DiagnosticsNode>[
          ErrorDescription(' * "$id" was claimed by:'),
          ...buckets.map((RestorationBucket bucket) => ErrorDescription('   * ${bucket.debugOwner}')),
          ErrorDescription('   * ${_claimedChildren[id].debugOwner} (current owner)'),
        ]);
      }
      throw FlutterError.fromParts(error);
    }());
    return true;
  }

  void _removeChildData(RestorationBucket child) {
    assert(child != null);
    assert(child._parent == this);
    if (_claimedChildren.remove(child.restorationId) == child) {
      _rawChildren.remove(child.restorationId);
      final List<RestorationBucket> pendingChildren = _childrenToAdd[child.restorationId];
      if (pendingChildren != null) {
        final RestorationBucket toAdd = pendingChildren.removeLast();
        _finalizeAddChildData(toAdd);
        if (pendingChildren.isEmpty) {
          _childrenToAdd.remove(child.restorationId);
        }
      }
      if (_rawChildren.isEmpty) {
        _rawData.remove(_childrenMapKey);
      }
      _markNeedsSerialization();
      return;
    }
    _childrenToAdd[child.restorationId]?.remove(child);
    if (_childrenToAdd[child.restorationId]?.isEmpty == true) {
      _childrenToAdd.remove(child.restorationId);
    }
  }

  void _addChildData(RestorationBucket child) {
    assert(child != null);
    assert(child._parent == this);
    if (_claimedChildren.containsKey(child.restorationId)) {
      // Delay addition until the end of the frame in the hopes that the current
      // owner of the child with the same ID will have given up that child by
      // then.
      _childrenToAdd.putIfAbsent(child.restorationId, () => <RestorationBucket>[]).add(child);
      _markNeedsSerialization();
      return;
    }
    _finalizeAddChildData(child);
    _markNeedsSerialization();
  }

  void _finalizeAddChildData(RestorationBucket child) {
    assert(_claimedChildren[child.restorationId] == null);
    assert(_rawChildren[child.restorationId] == null);
    _claimedChildren[child.restorationId] = child;
    _rawChildren[child.restorationId] = child._rawData;
  }

  void _visitChildren(_BucketVisitor visitor, {bool concurrentModification = false}) {
    Iterable<RestorationBucket> children = _claimedChildren.values
        .followedBy(_childrenToAdd.values.expand((List<RestorationBucket> buckets) => buckets));
    if (concurrentModification) {
      children = children.toList(growable: false);
    }
    children.forEach(visitor);
  }

  // Bucket management

  /// Changes the restoration ID under which the bucket is stored in its parent
  /// to `newRestorationId`.
  ///
  /// No-op if the bucket is already stored under the provided id.
  ///
  /// If another owner has already claimed a bucket with the provided `newId` an
  /// exception will be thrown at the end of the current frame unless the other
  /// owner has deleted its bucket by calling [dispose], [rename]ed it using
  /// another ID, or has moved it to a new parent via [adoptChild].
  void rename(String newRestorationId) {
    assert(_debugAssertNotDisposed());
    assert(newRestorationId != null);
    assert(_parent != null);
    if (newRestorationId == restorationId) {
      return;
    }
    _parent._removeChildData(this);
    _restorationId = newRestorationId;
    _parent._addChildData(this);
  }

  /// Deletes the bucket and all the data stored in it from the bucket
  /// hierarchy.
  ///
  /// After [dispose] has been called, the data stored in this bucket and its
  /// children are no longer part of the app's restoration data. The data
  /// originally stored in the bucket will not be available again when the
  /// application is restored to this state in the future. It is up to the
  /// owners of the children to either move them (via [adoptChild]) to a new
  /// parent that is still part of the bucket hierarchy or to [dispose] of them
  /// as well.
  ///
  /// This method must only be called by the object's owner.
  @override
  void dispose() {
    assert(_debugAssertNotDisposed());
    _visitChildren(_dropChild, concurrentModification: true);
    _claimedChildren.clear();
    _childrenToAdd.clear();
    _parent?._removeChildData(this);
    _parent = null;
    _updateManager(null);
    super.dispose();
    _debugDisposed = true;
  }

  @override
  String toString() => '${objectRuntimeType(this, 'RestorationBucket')}(restorationId: $restorationId, owner: $debugOwner)';

  bool _debugDisposed = false;
  bool _debugAssertNotDisposed() {
    assert(() {
      if (_debugDisposed) {
        throw FlutterError(
            'A $runtimeType was used after being disposed.\n'
            'Once you have called dispose() on a $runtimeType, it can no longer be used.'
        );
      }
      return true;
    }());
    return true;
  }
}

/// Returns true when the provided `object` is serializable for state
/// restoration.
///
/// Should only be called from within asserts. Always returns false outside
/// of debug builds.
bool debugIsSerializableForRestoration(Object object) {
  bool result = false;

  assert(() {
    try {
      const StandardMessageCodec().encodeMessage(object);
      result = true;
    } catch (_) {
      result = false;
    }
    return true;
  }());

  return result;
}