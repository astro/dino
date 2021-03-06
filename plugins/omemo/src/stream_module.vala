using Gee;
using Xmpp;
using Xmpp.Core;
using Xmpp.Xep;
using Signal;

namespace Dino.Plugins.Omemo {

private const string NS_URI = "eu.siacs.conversations.axolotl";
private const string NODE_DEVICELIST = NS_URI + ".devicelist";
private const string NODE_BUNDLES = NS_URI + ".bundles";
private const string NODE_VERIFICATION = NS_URI + ".verification";

private const int NUM_KEYS_TO_PUBLISH = 100;

public class StreamModule : XmppStreamModule {
    public static Core.ModuleIdentity<StreamModule> IDENTITY = new Core.ModuleIdentity<StreamModule>(NS_URI, "omemo_module");

    private Store store;
    private ConcurrentSet<string> active_bundle_requests = new ConcurrentSet<string>();
    private ConcurrentSet<string> active_devicelist_requests = new ConcurrentSet<string>();
    private Map<string, ArrayList<int32>> device_lists = new HashMap<string, ArrayList<int32>>();
    private Map<string, ArrayList<int32>> ignored_devices = new HashMap<string, ArrayList<int32>>();

    public signal void store_created(Store store);
    public signal void device_list_loaded(string jid);
    public signal void session_started(string jid, int device_id);
    public signal void session_start_failed(string jid, int device_id);

    public EncryptState encrypt(Message.Stanza message, string self_bare_jid) {
        EncryptState status = new EncryptState();
        if (!Plugin.ensure_context()) return status;
        if (message.to == null) return status;
        try {
            string name = get_bare_jid((!)message.to);
            if (!device_lists.has_key(self_bare_jid)) return status;
            status.own_list = true;
            status.own_devices = device_lists.get(self_bare_jid).size;
            if (!device_lists.has_key(name)) return status;
            status.other_list = true;
            status.other_devices = device_lists.get(name).size;
            if (status.own_devices == 0 || status.other_devices == 0) return status;

            uint8[] key = new uint8[16];
            Plugin.get_context().randomize(key);
            uint8[] iv = new uint8[16];
            Plugin.get_context().randomize(iv);

            uint8[] ciphertext = aes_encrypt(Cipher.AES_GCM_NOPADDING, key, iv, message.body.data);

            StanzaNode header;
            StanzaNode encrypted = new StanzaNode.build("encrypted", NS_URI).add_self_xmlns()
                    .put_node(header = new StanzaNode.build("header", NS_URI)
                        .put_attribute("sid", store.local_registration_id.to_string())
                        .put_node(new StanzaNode.build("iv", NS_URI)
                            .put_node(new StanzaNode.text(Base64.encode(iv)))))
                    .put_node(new StanzaNode.build("payload", NS_URI)
                        .put_node(new StanzaNode.text(Base64.encode(ciphertext))));

            Address address = new Address(name, 0);
            foreach(int32 device_id in device_lists[name]) {
                if (is_ignored_device(name, device_id)) {
                    status.other_lost++;
                    continue;
                }
                try {
                    address.device_id = (int) device_id;
                    StanzaNode key_node = create_encrypted_key(key, address);
                    header.put_node(key_node);
                    status.other_success++;
                } catch (Error e) {
                    if (e.code == ErrorCode.UNKNOWN) status.other_unknown++;
                    else status.other_failure++;
                }
            }
            address.name = self_bare_jid;
            foreach(int32 device_id in device_lists[self_bare_jid]) {
                if (is_ignored_device(self_bare_jid, device_id)) {
                    status.own_lost++;
                    continue;
                }
                if (device_id != store.local_registration_id) {
                    address.device_id = (int) device_id;
                    try {
                        StanzaNode key_node = create_encrypted_key(key, address);
                        header.put_node(key_node);
                        status.own_success++;
                    } catch (Error e) {
                        if (e.code == ErrorCode.UNKNOWN) status.own_unknown++;
                        else status.own_failure++;
                    }
                }
            }

            message.stanza.put_node(encrypted);
            message.body = "[This message is OMEMO encrypted]";
            status.encrypted = true;
        } catch (Error e) {
            if (Plugin.DEBUG) print(@"OMEMO: Signal error while encrypting message: $(e.message)\n");
        }
        return status;
    }

    private StanzaNode create_encrypted_key(uint8[] key, Address address) throws GLib.Error {
        SessionCipher cipher = store.create_session_cipher(address);
        CiphertextMessage device_key = cipher.encrypt(key);
        StanzaNode key_node = new StanzaNode.build("key", NS_URI)
            .put_attribute("rid", address.device_id.to_string())
            .put_node(new StanzaNode.text(Base64.encode(device_key.serialized)));
        if (device_key.type == CiphertextType.PREKEY) key_node.put_attribute("prekey", "true");
        return key_node;
    }

    public override void attach(XmppStream stream) {
        Message.Module.require(stream);
        Pubsub.Module.require(stream);
        if (!Plugin.ensure_context()) return;

        this.store = Plugin.get_context().create_store();
        store_created(store);
        stream.get_module(Message.Module.IDENTITY).pre_received_message.connect(on_pre_received_message);
        stream.get_module(Pubsub.Module.IDENTITY).add_filtered_notification(stream, NODE_DEVICELIST, (stream, jid, id, node, obj) => ((StreamModule)obj).on_devicelist(stream, jid, id, node), this);
    }

    private void on_pre_received_message(XmppStream stream, Message.Stanza message) {
        StanzaNode? _encrypted = message.stanza.get_subnode("encrypted", NS_URI);
        if (_encrypted == null || MessageFlag.get_flag(message) != null || message.from == null) return;
        StanzaNode encrypted = (!)_encrypted;
        if (!Plugin.ensure_context()) return;
        MessageFlag flag = new MessageFlag();
        message.add_flag(flag);
        StanzaNode? _header = encrypted.get_subnode("header");
        if (_header == null) return;
        StanzaNode header = (!)_header;
        if (header.get_attribute_int("sid") <= 0) return;
        foreach (StanzaNode key_node in header.get_subnodes("key")) {
            if (key_node.get_attribute_int("rid") == store.local_registration_id) {
                try {
                    string? payload = encrypted.get_deep_string_content("payload");
                    string? iv_node = header.get_deep_string_content("iv");
                    string? key_node_content = key_node.get_string_content();
                    if (payload == null || iv_node == null || key_node_content == null) continue;
                    uint8[] key;
                    uint8[] ciphertext = Base64.decode((!)payload);
                    uint8[] iv = Base64.decode((!)iv_node);
                    Address address = new Address(get_bare_jid((!)message.from), header.get_attribute_int("sid"));
                    if (key_node.get_attribute_bool("prekey")) {
                        PreKeySignalMessage msg = Plugin.get_context().deserialize_pre_key_signal_message(Base64.decode((!)key_node_content));
                        SessionCipher cipher = store.create_session_cipher(address);
                        key = cipher.decrypt_pre_key_signal_message(msg);
                    } else {
                        SignalMessage msg = Plugin.get_context().deserialize_signal_message(Base64.decode((!)key_node_content));
                        SessionCipher cipher = store.create_session_cipher(address);
                        key = cipher.decrypt_signal_message(msg);
                    }
                    address.device_id = 0; // TODO: Hack to have address obj live longer

                    if (key.length >= 32) {
                        int authtaglength = key.length - 16;
                        uint8[] new_ciphertext = new uint8[ciphertext.length + authtaglength];
                        uint8[] new_key = new uint8[16];
                        Memory.copy(new_ciphertext, ciphertext, ciphertext.length);
                        Memory.copy((uint8*)new_ciphertext + ciphertext.length, (uint8*)key + 16, authtaglength);
                        Memory.copy(new_key, key, 16);
                        ciphertext = new_ciphertext;
                        key = new_key;
                    }

                    message.body = arr_to_str(aes_decrypt(Cipher.AES_GCM_NOPADDING, key, iv, ciphertext));
                    flag.decrypted = true;
                } catch (Error e) {
                    if (Plugin.DEBUG) print(@"OMEMO: Signal error while decrypting message: $(e.message)\n");
                }
            }
        }
    }

    private string arr_to_str(uint8[] arr) {
        // null-terminate the array
        uint8[] rarr = new uint8[arr.length+1];
        Memory.copy(rarr, arr, arr.length);
        return (string)rarr;
    }

    public void request_user_devicelist(XmppStream stream, string jid) {
        if (active_devicelist_requests.add(jid)) {
            if (Plugin.DEBUG) print(@"OMEMO: requesting device list for $jid\n");
            stream.get_module(Pubsub.Module.IDENTITY).request(stream, jid, NODE_DEVICELIST, (stream, jid, id, node, obj) => ((StreamModule)obj).on_devicelist(stream, jid, id ?? "", node), this);
        }
    }

    public void on_devicelist(XmppStream stream, string jid, string id, StanzaNode? node_) {
        StanzaNode node = node_ ?? new StanzaNode.build("list", NS_URI).add_self_xmlns();
        string? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid == null) return;
        if (jid == get_bare_jid((!)my_jid) && store.local_registration_id != 0) {
            bool am_on_devicelist = false;
            foreach (StanzaNode device_node in node.get_subnodes("device")) {
                int device_id = device_node.get_attribute_int("id");
                if (store.local_registration_id == device_id) {
                    am_on_devicelist = true;
                }
            }
            if (!am_on_devicelist) {
                if (Plugin.DEBUG) print(@"OMEMO: Not on device list, adding id\n");
                node.put_node(new StanzaNode.build("device", NS_URI).put_attribute("id", store.local_registration_id.to_string()));
                stream.get_module(Pubsub.Module.IDENTITY).publish(stream, jid, NODE_DEVICELIST, NODE_DEVICELIST, id, node);
            } else {
                publish_bundles_if_needed(stream, jid);
            }
        }
        lock(device_lists) {
            device_lists[jid] = new ArrayList<int32>();
            foreach (StanzaNode device_node in node.get_subnodes("device")) {
                device_lists[jid].add(device_node.get_attribute_int("id"));
            }
        }
        active_devicelist_requests.remove(jid);
        device_list_loaded(jid);
    }

    public void start_sessions_with(XmppStream stream, string bare_jid) {
        if (!device_lists.has_key(bare_jid)) {
            // TODO: manually request a device list
            return;
        }
        Address address = new Address(bare_jid, 0);
        foreach(int32 device_id in device_lists[bare_jid]) {
            if (!is_ignored_device(bare_jid, device_id)) {
                address.device_id = device_id;
                try {
                    if (!store.contains_session(address)) {
                        start_session_with(stream, bare_jid, device_id);
                    }
                } catch (Error e) {
                    // Ignore
                }
            }
        }
        address.device_id = 0;
    }

    public void start_session_with(XmppStream stream, string bare_jid, int device_id) {
        if (active_bundle_requests.add(bare_jid + @":$device_id")) {
            if (Plugin.DEBUG) print(@"OMEMO: Asking for bundle from $bare_jid:$device_id\n");
            stream.get_module(Pubsub.Module.IDENTITY).request(stream, bare_jid, @"$NODE_BUNDLES:$device_id", on_other_bundle_result, Tuple.create(store, device_id));
        }
    }

    public bool is_known_address(string name) {
        return device_lists.has_key(name);
    }

    public void ignore_device(string jid, int32 device_id) {
        if (device_id <= 0) return;
        lock (ignored_devices) {
            if (!ignored_devices.has_key(jid)) {
                ignored_devices[jid] = new ArrayList<int32>();
            }
            ignored_devices[jid].add(device_id);
        }
        session_start_failed(jid, device_id);
    }

    public bool is_ignored_device(string jid, int32 device_id) {
        if (device_id <= 0) return true;
        lock (ignored_devices) {
            return ignored_devices.has_key(jid) && ignored_devices[jid].contains(device_id);
        }
    }

    private static void on_other_bundle_result(XmppStream stream, string jid, string? id, StanzaNode? node, Object? storage) {
        Tuple<Store, int> tuple = (Tuple<Store, int>)storage;
        Store store = tuple.a;
        int device_id = tuple.b;

        bool fail = false;
        if (node == null) {
            // Device not registered, shouldn't exist
            fail = true;
        } else {
            Bundle bundle = new Bundle(node);
            int32 signed_pre_key_id = bundle.signed_pre_key_id;
            ECPublicKey? signed_pre_key = bundle.signed_pre_key;
            uint8[] signed_pre_key_signature = bundle.signed_pre_key_signature;
            ECPublicKey? identity_key = bundle.identity_key;

            ArrayList<Bundle.PreKey> pre_keys = bundle.pre_keys;
            int pre_key_idx = Random.int_range(0, pre_keys.size);
            int32 pre_key_id = pre_keys[pre_key_idx].key_id;
            ECPublicKey? pre_key = pre_keys[pre_key_idx].key;

            if (signed_pre_key_id < 0 || signed_pre_key == null || identity_key == null || pre_key_id < 0 || pre_key == null) {
                fail = true;
            } else {
                Address address = new Address(jid, device_id);
                try {
                    if (store.contains_session(address)) {
                        return;
                    }
                    SessionBuilder builder = store.create_session_builder(address);
                    builder.process_pre_key_bundle(create_pre_key_bundle(device_id, device_id, pre_key_id, pre_key, signed_pre_key_id, signed_pre_key, signed_pre_key_signature, identity_key));
                    stream.get_module(IDENTITY).session_started(jid, device_id);
                } catch (Error e) {
                    fail = true;
                }
                address.device_id = 0; // TODO: Hack to have address obj live longer
            }
        }
        if (fail) {
            stream.get_module(IDENTITY).ignore_device(jid, device_id);
        }
        stream.get_module(IDENTITY).active_bundle_requests.remove(jid + @":$device_id");
    }

    public void publish_bundles_if_needed(XmppStream stream, string jid) {
        if (active_bundle_requests.add(jid + @":$(store.local_registration_id)")) {
            stream.get_module(Pubsub.Module.IDENTITY).request(stream, jid, @"$NODE_BUNDLES:$(store.local_registration_id)", on_self_bundle_result, store);
        }
    }

    private static void on_self_bundle_result(XmppStream stream, string jid, string? id, StanzaNode? node, Object? storage) {
        if (!Plugin.ensure_context()) return;
        Store store = (Store)storage;
        Map<int, ECPublicKey> keys = new HashMap<int, ECPublicKey>();
        ECPublicKey? identity_key = null;
        int32 signed_pre_key_id = -1;
        ECPublicKey? signed_pre_key = null;
        SignedPreKeyRecord? signed_pre_key_record = null;
        bool changed = false;
        if (node == null) {
            identity_key = store.identity_key_pair.public;
            changed = true;
        } else {
            Bundle bundle = new Bundle(node);
            foreach (Bundle.PreKey prekey in bundle.pre_keys) {
                ECPublicKey? key = prekey.key;
                if (key != null) {
                    keys[prekey.key_id] = (!)key;
                }
            }
            identity_key = bundle.identity_key;
            signed_pre_key_id = bundle.signed_pre_key_id;;
            signed_pre_key = bundle.signed_pre_key;
        }

        try {
            // Validate IdentityKey
            if (identity_key == null || store.identity_key_pair.public.compare((!)identity_key) != 0) {
                changed = true;
            }
            IdentityKeyPair identity_key_pair = store.identity_key_pair;

            // Validate signedPreKeyRecord + ID
            if (signed_pre_key == null || signed_pre_key_id == -1 || !store.contains_signed_pre_key(signed_pre_key_id) || store.load_signed_pre_key(signed_pre_key_id).key_pair.public.compare((!)signed_pre_key) != 0) {
                signed_pre_key_id = Random.int_range(1, int32.MAX); // TODO: No random, use ordered number
                signed_pre_key_record = Plugin.get_context().generate_signed_pre_key(identity_key_pair, signed_pre_key_id);
                store.store_signed_pre_key((!)signed_pre_key_record);
                changed = true;
            } else {
                signed_pre_key_record = store.load_signed_pre_key(signed_pre_key_id);
            }

            // Validate PreKeys
            Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord>();
            foreach (var entry in keys.entries) {
                if (store.contains_pre_key(entry.key)) {
                    PreKeyRecord record = store.load_pre_key(entry.key);
                    if (record.key_pair.public.compare(entry.value) == 0) {
                        pre_key_records.add(record);
                    }
                }
            }
            int new_keys = NUM_KEYS_TO_PUBLISH - pre_key_records.size;
            if (new_keys > 0) {
                int32 next_id = Random.int_range(1, int32.MAX); // TODO: No random, use ordered number
                Set<PreKeyRecord> new_records = Plugin.get_context().generate_pre_keys((uint)next_id, (uint)new_keys);
                pre_key_records.add_all(new_records);
                foreach (PreKeyRecord record in new_records) {
                    store.store_pre_key(record);
                }
                changed = true;
            }

            if (changed) {
                publish_bundles(stream, (!)signed_pre_key_record, identity_key_pair, pre_key_records, (int32) store.local_registration_id);
            }
        } catch (Error e) {
            if (Plugin.DEBUG) print(@"Unexpected error while publishing bundle: $(e.message)\n");
        }
        stream.get_module(IDENTITY).active_bundle_requests.remove(jid + @":$(store.local_registration_id)");
    }

    public static void publish_bundles(XmppStream stream, SignedPreKeyRecord signed_pre_key_record, IdentityKeyPair identity_key_pair, Set<PreKeyRecord> pre_key_records, int32 device_id) throws Error {
        ECKeyPair tmp;
        StanzaNode bundle = new StanzaNode.build("bundle", NS_URI)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("signedPreKeyPublic", NS_URI)
                    .put_attribute("signedPreKeyId", signed_pre_key_record.id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode((tmp = signed_pre_key_record.key_pair).public.serialize()))))
                .put_node(new StanzaNode.build("signedPreKeySignature", NS_URI)
                    .put_node(new StanzaNode.text(Base64.encode(signed_pre_key_record.signature))))
                .put_node(new StanzaNode.build("identityKey", NS_URI)
                    .put_node(new StanzaNode.text(Base64.encode(identity_key_pair.public.serialize()))));
        StanzaNode prekeys = new StanzaNode.build("prekeys", NS_URI);
        foreach (PreKeyRecord pre_key_record in pre_key_records) {
            prekeys.put_node(new StanzaNode.build("preKeyPublic", NS_URI)
                    .put_attribute("preKeyId", pre_key_record.id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(pre_key_record.key_pair.public.serialize()))));
        }
        bundle.put_node(prekeys);

        stream.get_module(Pubsub.Module.IDENTITY).publish(stream, null, @"$NODE_BUNDLES:$device_id", @"$NODE_BUNDLES:$device_id", "1", bundle);
    }

    public override void detach(XmppStream stream) {

    }

    public override string get_ns() {
        return NS_URI;
    }

    public override string get_id() {
        return IDENTITY.id;
    }
}

}