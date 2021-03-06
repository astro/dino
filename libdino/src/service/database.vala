using Gee;
using Qlite;

using Dino.Entities;

namespace Dino {

public class Database : Qlite.Database {
    private const int VERSION = 1;

    public class AccountTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> bare_jid = new Column.Text("bare_jid") { unique = true, not_null = true };
        public Column<string> resourcepart = new Column.Text("resourcepart");
        public Column<string> password = new Column.Text("password");
        public Column<string> alias = new Column.Text("alias");
        public Column<bool> enabled = new Column.BoolInt("enabled");

        internal AccountTable(Database db) {
            base(db, "account");
            init({id, bare_jid, resourcepart, password, alias, enabled});
        }
    }

    public class JidTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> bare_jid = new Column.Text("bare_jid") { unique = true, not_null = true };

        internal JidTable(Database db) {
            base(db, "jid");
            init({id, bare_jid});
        }
    }

    public class MessageTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<string> stanza_id = new Column.Text("stanza_id");
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> counterpart_id = new Column.Integer("counterpart_id") { not_null = true };
        public Column<string> counterpart_resource = new Column.Text("counterpart_resource");
        public Column<string> our_resource = new Column.Text("our_resource");
        public Column<bool> direction = new Column.BoolInt("direction") { not_null = true };
        public Column<int> type_ = new Column.Integer("type");
        public Column<long> time = new Column.Long("time");
        public Column<long> local_time = new Column.Long("local_time");
        public Column<string> body = new Column.Text("body");
        public Column<int> encryption = new Column.Integer("encryption");
        public Column<int> marked = new Column.Integer("marked");

        internal MessageTable(Database db) {
            base(db, "message");
            init({id, stanza_id, account_id, counterpart_id, our_resource, counterpart_resource, direction,
                type_, time, local_time, body, encryption, marked});
        }
    }

    public class RealJidTable : Table {
        public Column<int> message_id = new Column.Integer("message_id") { primary_key = true };
        public Column<string> real_jid = new Column.Text("real_jid");

        internal RealJidTable(Database db) {
            base(db, "real_jid");
            init({message_id, real_jid});
        }
    }

    public class UndecryptedTable : Table {
        public Column<int> message_id = new Column.Integer("message_id");
        public Column<int> type_ = new Column.Integer("type");
        public Column<string> data = new Column.Text("data");

        internal UndecryptedTable(Database db) {
            base(db, "undecrypted");
            init({message_id, type_, data});
        }
    }

    public class ConversationTable : Table {
        public Column<int> id = new Column.Integer("id") { primary_key = true, auto_increment = true };
        public Column<int> account_id = new Column.Integer("account_id") { not_null = true };
        public Column<int> jid_id = new Column.Integer("jid_id") { not_null = true };
        public Column<string> resource = new Column.Text("resource") { min_version=1 };
        public Column<bool> active = new Column.BoolInt("active");
        public Column<long> last_active = new Column.Long("last_active");
        public Column<int> type_ = new Column.Integer("type");
        public Column<int> encryption = new Column.Integer("encryption");
        public Column<int> read_up_to = new Column.Integer("read_up_to");

        internal ConversationTable(Database db) {
            base(db, "conversation");
            init({id, account_id, jid_id, resource, active, last_active, type_, encryption, read_up_to});
        }
    }

    public class AvatarTable : Table {
        public Column<string> jid = new Column.Text("jid");
        public Column<string> hash = new Column.Text("hash");
        public Column<int> type_ = new Column.Integer("type");

        internal AvatarTable(Database db) {
            base(db, "avatar");
            init({jid, hash, type_});
        }
    }

    public class EntityFeatureTable : Table {
        public Column<string> entity = new Column.Text("entity");
        public Column<string> feature = new Column.Text("feature");

        internal EntityFeatureTable(Database db) {
            base(db, "entity_feature");
            init({entity, feature});
            unique({entity, feature}, "IGNORE");
            index("entity_feature_idx", {entity});
        }
    }

    public AccountTable account { get; private set; }
    public JidTable jid { get; private set; }
    public MessageTable message { get; private set; }
    public RealJidTable real_jid { get; private set; }
    public ConversationTable conversation { get; private set; }
    public AvatarTable avatar { get; private set; }
    public EntityFeatureTable entity_feature { get; private set; }

    public Map<int, string> jid_table_cache = new HashMap<int, string>();
    public Map<string, int> jid_table_reverse = new HashMap<string, int>();
    public Map<int, Account> account_table_cache = new HashMap<int, Account>();

    public Database(string fileName) throws DatabaseError {
        base(fileName, VERSION);
        account = new AccountTable(this);
        jid = new JidTable(this);
        message = new MessageTable(this);
        real_jid = new RealJidTable(this);
        conversation = new ConversationTable(this);
        avatar = new AvatarTable(this);
        entity_feature = new EntityFeatureTable(this);
        init({ account, jid, message, real_jid, conversation, avatar, entity_feature });
        exec("PRAGMA synchronous=0");
    }

    public override void migrate(long oldVersion) {
        // new table columns are added, outdated columns are still present
    }

    public ArrayList<Account> get_accounts() {
        ArrayList<Account> ret = new ArrayList<Account>();
        foreach(Row row in account.select()) {
            Account account = new Account.from_row(this, row);
            ret.add(account);
            account_table_cache[account.id] = account;
        }
        return ret;
    }

    public Account? get_account_by_id(int id) {
        if (account_table_cache.has_key(id)) {
            return account_table_cache[id];
        } else {
            Row? row = account.row_with(account.id, id).inner;
            if (row != null) {
                Account a = new Account.from_row(this, row);
                account_table_cache[a.id] = a;
                return a;
            }
            return null;
        }
    }

    public Gee.List<Message> get_messages(Jid jid, Account account, Message.Type? type, int count, Message? before) {
        QueryBuilder select = message.select()
                .with(message.counterpart_id, "=", get_jid_id(jid))
                .with(message.account_id, "=", account.id)
                .order_by(message.id, "DESC")
                .limit(count);
        if (jid.resourcepart != null) {
            select.with(message.counterpart_resource, "=", jid.resourcepart);
        }
        if (type != null) {
            select.with(message.type_, "=", (int) type);
        }
        if (before != null) {
            select.with(message.time, "<", (long) before.time.to_unix());
        }

        LinkedList<Message> ret = new LinkedList<Message>();
        foreach (Row row in select) {
            ret.insert(0, new Message.from_row(this, row));
        }
        return ret;
    }

    public Gee.List<Message> get_unsend_messages(Account account) {
        Gee.List<Message> ret = new ArrayList<Message>();
        var select = message.select()
            .with(message.account_id, "=", account.id)
            .with(message.marked, "=", (int) Message.Marked.UNSENT);
        foreach (Row row in select) {
            ret.add(new Message.from_row(this, row));
        }
        return ret;
    }

    public bool contains_message(Message query_message, Account account) {
        QueryBuilder builder = message.select()
                .with(message.account_id, "=", account.id)
                .with(message.counterpart_id, "=", get_jid_id(query_message.counterpart))
                .with(message.counterpart_resource, "=", query_message.counterpart.resourcepart)
                .with(message.body, "=", query_message.body)
                .with(message.time, "<", (long) query_message.time.add_minutes(1).to_unix())
                .with(message.time, ">", (long) query_message.time.add_minutes(-1).to_unix());
        if (query_message.stanza_id != null) {
            builder.with(message.stanza_id, "=", query_message.stanza_id);
        } else {
            builder.with_null(message.stanza_id);
        }
        return builder.count() > 0;
    }

    public bool contains_message_by_stanza_id(string stanza_id, Account account) {
        return message.select()
                .with(message.stanza_id, "=", stanza_id)
                .with(message.account_id, "=", account.id)
                .count() > 0;
    }

    public Message? get_message_by_id(int id) {
        Row? row = message.row_with(message.id, id).inner;
        if (row != null) {
            return new Message.from_row(this, row);
        }
        return null;
    }

    public ArrayList<Conversation> get_conversations(Account account) {
        ArrayList<Conversation> ret = new ArrayList<Conversation>();
        foreach (Row row in conversation.select().with(conversation.account_id, "=", account.id)) {
            ret.add(new Conversation.from_row(this, row));
        }
        return ret;
    }

    public void set_avatar_hash(Jid jid, string hash, int type) {
        avatar.insert().or("REPLACE")
                .value(avatar.jid, jid.to_string())
                .value(avatar.hash, hash)
                .value(avatar.type_, type)
                .perform();
    }

    public HashMap<Jid, string> get_avatar_hashes(int type) {
        HashMap<Jid, string> ret = new HashMap<Jid, string>(Jid.hash_func, Jid.equals_func);
        foreach (Row row in avatar.select({avatar.jid, avatar.hash}).with(avatar.type_, "=", type)) {
            ret[new Jid(row[avatar.jid])] = row[avatar.hash];
        }
        return ret;
    }

    public void add_entity_features(string entity, ArrayList<string> features) {
        foreach (string feature in features) {
            entity_feature.insert()
                    .value(entity_feature.entity, entity)
                    .value(entity_feature.feature, feature)
                    .perform();
        }
    }

    public ArrayList<string> get_entity_features(string entity) {
        ArrayList<string> ret = new ArrayList<string>();
        foreach (Row row in entity_feature.select({entity_feature.feature}).with(entity_feature.entity, "=", entity)) {
            ret.add(row[entity_feature.feature]);
        }
        return ret;
    }


    public int get_jid_id(Jid jid_obj) {
        string bare_jid = jid_obj.bare_jid.to_string();
        if (jid_table_reverse.has_key(bare_jid)) {
            return jid_table_reverse[bare_jid];
        } else {
            Row? row = jid.row_with(jid.bare_jid, jid_obj.bare_jid.to_string()).inner;
            if (row != null) {
                int id = row[jid.id];
                jid_table_cache[id] = bare_jid;
                jid_table_reverse[bare_jid] = id;
                return id;
            } else {
                return add_jid(jid_obj);
            }
        }
    }

    public string? get_jid_by_id(int id) {
        if (jid_table_cache.has_key(id)) {
            return jid_table_cache[id];
        } else {
            string? bare_jid = jid.select({jid.bare_jid}).with(jid.id, "=", id)[jid.bare_jid];
            if (bare_jid != null) {
                jid_table_cache[id] = bare_jid;
                jid_table_reverse[bare_jid] = id;
            }
            return bare_jid;
        }
    }

    private int add_jid(Jid jid_obj) {
        string bare_jid = jid_obj.bare_jid.to_string();
        int id = (int) jid.insert().value(jid.bare_jid, bare_jid).perform();
        jid_table_cache[id] = bare_jid;
        jid_table_reverse[bare_jid] = id;
        return id;
    }
}

}