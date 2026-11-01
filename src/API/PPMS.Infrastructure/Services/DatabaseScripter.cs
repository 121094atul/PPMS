using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;

namespace PPMS.Infrastructure.Services;

/// <summary>
/// Poore database ki EK SQL file - roz ke backup email ke liye (Section BA). Shared server par
/// BACKUP DATABASE ki ijaazat nahi, isliye sab kuch sys.* se padh kar likhte hain:
///   schema -> table type -> table (column, identity, default, computed, PK / UNIQUE) -> saara data
///   (INSERT, IDENTITY_INSERT) -> index -> foreign key -> check -> function / view / procedure / trigger.
/// Khaali database par ye file chalao (sqlcmd -I ya SSMS) to poora DB wapas.
/// Koi table nahi chhoot-ti (token / OTP / login wali bhi).
/// </summary>
public sealed class DatabaseScripter(SqlConnection connection)
{
    private const int RowsPerInsert = 500;

    public sealed record Summary(int Tables, long Rows, int Modules, IReadOnlyList<(string Table, long Rows)> PerTable);

    private sealed record Col(string Name, string Type, short MaxLength, byte Precision, byte Scale, bool Nullable,
        bool IsIdentity, string? IdentitySeed, string? IdentityIncrement, string? Computed, bool Persisted,
        string? DefaultName, string? DefaultDef);

    public async Task<Summary> WriteAsync(TextWriter w, CancellationToken ct)
    {
        w.WriteLine("/* ==========================================================================================");
        w.WriteLine($"   PPMS - POORE DATABASE KA BACKUP ({connection.Database})");
        w.WriteLine($"   Bana: {DateTime.UtcNow.AddMinutes(330):dd-MMM-yyyy HH:mm} (India)");
        w.WriteLine("   WAPAS KAISE LAAYEIN:");
        w.WriteLine("     1. SQL Server me ek naya KHAALI database banaiye (jaise PPMS_RESTORE).");
        w.WriteLine("     2. Ye file usi database par chalaiye:");
        w.WriteLine("          sqlcmd -S <server> -d PPMS_RESTORE -E -I -i PPMS-full-backup.sql");
        w.WriteLine("        (ya SSMS me kholke us database par Execute).");
        w.WriteLine("   Isme: saari tables (structure + data), index, foreign key, function, procedure.");
        w.WriteLine("   ========================================================================================== */");
        w.WriteLine("SET NOCOUNT ON;");
        w.WriteLine("SET ANSI_NULLS ON;");
        w.WriteLine("SET QUOTED_IDENTIFIER ON;");
        w.WriteLine("GO");
        w.WriteLine();

        // ---- schema ----
        foreach (var s in await ListAsync(
            "SELECT DISTINCT s.name FROM sys.schemas s JOIN sys.objects o ON o.schema_id = s.schema_id " +
            "WHERE o.is_ms_shipped = 0 AND s.name NOT IN ('dbo','sys','INFORMATION_SCHEMA','guest') ORDER BY s.name", ct))
        {
            w.WriteLine($"IF SCHEMA_ID(N'{Lit(s)}') IS NULL EXEC(N'CREATE SCHEMA {Q(s)}');");
        }
        w.WriteLine("GO");
        w.WriteLine();

        // ---- table types ----
        var types = await RowsAsync(
            "SELECT SCHEMA_NAME(tt.schema_id), tt.name, tt.type_table_object_id FROM sys.table_types tt WHERE tt.is_user_defined = 1 ORDER BY tt.name", ct);
        foreach (var t in types)
        {
            var cols = await ColumnsAsync((int)t[2]!, ct);
            // Table type me naam wale constraint allowed nahi - default / PK bina naam ke.
            var typeLines = cols.Select(c => "    " + ColumnDef(c, includeDefaults: true, namedDefaults: false)).ToList();
            typeLines.AddRange(await KeyConstraintsAsync((int)t[2]!, ct, named: false));
            w.WriteLine($"CREATE TYPE {Q((string)t[0]!)}.{Q((string)t[1]!)} AS TABLE");
            w.WriteLine("(");
            w.WriteLine(string.Join(",\n", typeLines));
            w.WriteLine(");");
            w.WriteLine("GO");
        }
        w.WriteLine();

        // ---- tables (structure) ----
        var tables = (await RowsAsync(
            "SELECT t.object_id, SCHEMA_NAME(t.schema_id), t.name FROM sys.tables t WHERE t.is_ms_shipped = 0 ORDER BY SCHEMA_NAME(t.schema_id), t.name", ct))
            .Select(r => (Id: (int)r[0]!, Schema: (string)r[1]!, Name: (string)r[2]!)).ToList();

        var colsByTable = new Dictionary<int, List<Col>>();
        foreach (var t in tables)
        {
            var cols = await ColumnsAsync(t.Id, ct);
            colsByTable[t.Id] = cols;
            var lines = cols.Select(c => "    " + ColumnDef(c, includeDefaults: true)).ToList();
            lines.AddRange(await KeyConstraintsAsync(t.Id, ct));
            w.WriteLine($"CREATE TABLE {Q(t.Schema)}.{Q(t.Name)}");
            w.WriteLine("(");
            w.WriteLine(string.Join(",\n", lines));
            w.WriteLine(");");
            w.WriteLine("GO");
        }
        w.WriteLine();

        // ---- data ----
        var per = new List<(string, long)>();
        long total = 0;
        foreach (var t in tables)
        {
            var cols = colsByTable[t.Id].Where(c => c.Computed is null && c.Type != "timestamp").ToList();
            var n = await WriteDataAsync(w, t.Schema, t.Name, cols, colsByTable[t.Id].Any(c => c.IsIdentity), ct);
            per.Add(($"{t.Schema}.{t.Name}", n));
            total += n;
        }
        w.WriteLine();

        // ---- index, foreign key, check (data ke BAAD - load tez, kram ki fikr nahi) ----
        foreach (var t in tables)
        {
            foreach (var line in await IndexesAsync(t.Id, t.Schema, t.Name, ct)) { w.WriteLine(line); }
        }
        w.WriteLine("GO");
        foreach (var t in tables)
        {
            foreach (var line in await ForeignKeysAsync(t.Id, t.Schema, t.Name, ct)) { w.WriteLine(line); }
            foreach (var line in await ChecksAsync(t.Id, t.Schema, t.Name, ct)) { w.WriteLine(line); }
        }
        w.WriteLine("GO");
        w.WriteLine();

        // ---- function / view / procedure / trigger - asli code jaisa likha tha ----
        var modules = await RowsAsync(
            "SELECT o.type, m.definition, m.uses_ansi_nulls, m.uses_quoted_identifier, SCHEMA_NAME(o.schema_id) + '.' + o.name " +
            "FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id " +
            "WHERE o.is_ms_shipped = 0 AND o.type IN ('FN','IF','TF','V','P','TR') " +
            "ORDER BY CASE o.type WHEN 'FN' THEN 1 WHEN 'IF' THEN 1 WHEN 'TF' THEN 1 WHEN 'V' THEN 2 WHEN 'P' THEN 3 ELSE 4 END, o.create_date, o.name", ct);
        var written = 0;
        foreach (var m in modules)
        {
            if (m[1] is not string def) { w.WriteLine($"-- {m[4]}: code padhne ki ijaazat nahi thi"); continue; }
            w.WriteLine($"SET ANSI_NULLS {((bool)m[2]! ? "ON" : "OFF")};");
            w.WriteLine($"SET QUOTED_IDENTIFIER {((bool)m[3]! ? "ON" : "OFF")};");
            w.WriteLine("GO");
            w.WriteLine(def.Trim());
            w.WriteLine("GO");
            written++;
        }
        w.WriteLine("SET ANSI_NULLS ON;");
        w.WriteLine("SET QUOTED_IDENTIFIER ON;");
        w.WriteLine("GO");
        w.WriteLine($"PRINT 'PPMS backup wapas aa gaya: {tables.Count} tables, {total} rows, {written} procedures / functions.';");
        w.WriteLine("GO");

        return new Summary(tables.Count, total, written, per);
    }

    // ------------------------------------------------------------------ data

    private async Task<long> WriteDataAsync(TextWriter w, string schema, string name, List<Col> cols, bool hasIdentity, CancellationToken ct)
    {
        var full = $"{Q(schema)}.{Q(name)}";
        var colList = string.Join(", ", cols.Select(c => Q(c.Name)));
        await using var cmd = new SqlCommand($"SELECT {colList} FROM {full}", connection) { CommandTimeout = 600 };
        await using var r = await cmd.ExecuteReaderAsync(ct);

        long n = 0;
        var inBatch = 0;
        var sb = new StringBuilder();
        while (await r.ReadAsync(ct))
        {
            if (n == 0)
            {
                w.WriteLine($"-- {schema}.{name}");
                if (hasIdentity) { w.WriteLine($"SET IDENTITY_INSERT {full} ON;"); }
            }

            if (inBatch == 0)
            {
                w.Write($"INSERT INTO {full} ({colList}) VALUES\n");
            }
            else
            {
                w.Write(",\n");
            }

            sb.Clear().Append('(');
            for (var i = 0; i < cols.Count; i++)
            {
                if (i > 0) sb.Append(", ");
                sb.Append(r.IsDBNull(i) ? "NULL" : Literal(cols[i].Type, r.GetValue(i)));
            }
            sb.Append(')');
            w.Write(sb.ToString());

            n++;
            inBatch++;
            if (inBatch == RowsPerInsert)
            {
                w.WriteLine(";");
                inBatch = 0;
            }
        }

        if (inBatch > 0) w.WriteLine(";");
        if (n > 0)
        {
            if (hasIdentity) { w.WriteLine($"SET IDENTITY_INSERT {full} OFF;"); }
            w.WriteLine("GO");
        }
        return n;
    }

    private static string Literal(string type, object v)
    {
        var inv = CultureInfo.InvariantCulture;
        switch (type)
        {
            case "bit": return (bool)v ? "1" : "0";
            case "tinyint": case "smallint": case "int": case "bigint":
            case "decimal": case "numeric": case "money": case "smallmoney":
                return Convert.ToString(v, inv)!;
            case "float": return ((double)v).ToString("R", inv);
            case "real": return ((float)v).ToString("R", inv);
            case "date": return $"'{(DateTime)v:yyyy-MM-dd}'";
            case "datetime": return $"'{((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss.fff", inv)}'";
            case "smalldatetime": return $"'{((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss", inv)}'";
            case "datetime2": return $"'{((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss.fffffff", inv)}'";
            case "datetimeoffset": return $"'{((DateTimeOffset)v).ToString("yyyy-MM-ddTHH:mm:ss.fffffffzzz", inv)}'";
            case "time": return $"'{((TimeSpan)v).ToString(@"hh\:mm\:ss\.fffffff", inv)}'";
            case "uniqueidentifier": return $"'{v}'";
            case "binary": case "varbinary": case "image":
                return "0x" + Convert.ToHexString((byte[])v);
            case "char": case "varchar": case "text":
                return "'" + Lit(Convert.ToString(v, inv)!) + "'";
            default: // nchar, nvarchar, ntext, xml, sql_variant...
                return "N'" + Lit(Convert.ToString(v, inv)!) + "'";
        }
    }

    // ------------------------------------------------------------------ structure

    private async Task<List<Col>> ColumnsAsync(int objectId, CancellationToken ct)
    {
        var rows = await RowsAsync(
            "SELECT c.name, TYPE_NAME(c.system_type_id), c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity, " +
            "CONVERT(NVARCHAR(40), ic.seed_value), CONVERT(NVARCHAR(40), ic.increment_value), cc.definition, ISNULL(cc.is_persisted, 0), " +
            "dc.name, dc.definition " +
            "FROM sys.columns c " +
            "LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id " +
            "LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id " +
            "LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id " +
            $"WHERE c.object_id = {objectId} ORDER BY c.column_id", ct);

        return rows.Select(r => new Col(
            (string)r[0]!, (string)r[1]!, (short)r[2]!, (byte)r[3]!, (byte)r[4]!, (bool)r[5]!, (bool)r[6]!,
            r[7] as string, r[8] as string, r[9] as string, (bool)r[10]!, r[11] as string, r[12] as string)).ToList();
    }

    private static string TypeDef(Col c) => c.Type switch
    {
        "varchar" or "char" or "varbinary" or "binary" => $"{c.Type}({(c.MaxLength == -1 ? "MAX" : c.MaxLength.ToString(CultureInfo.InvariantCulture))})",
        "nvarchar" or "nchar" => $"{c.Type}({(c.MaxLength == -1 ? "MAX" : (c.MaxLength / 2).ToString(CultureInfo.InvariantCulture))})",
        "decimal" or "numeric" => $"{c.Type}({c.Precision},{c.Scale})",
        "datetime2" or "time" or "datetimeoffset" => $"{c.Type}({c.Scale})",
        "timestamp" => "rowversion",
        _ => c.Type
    };

    private static string ColumnDef(Col c, bool includeDefaults, bool namedDefaults = true)
    {
        if (c.Computed is not null)
        {
            return $"{Q(c.Name)} AS {c.Computed}{(c.Persisted ? " PERSISTED" : string.Empty)}";
        }

        var sb = new StringBuilder($"{Q(c.Name)} {TypeDef(c)}");
        if (c.IsIdentity) sb.Append($" IDENTITY({c.IdentitySeed ?? "1"},{c.IdentityIncrement ?? "1"})");
        sb.Append(c.Nullable ? " NULL" : " NOT NULL");
        if (includeDefaults && c.DefaultDef is not null)
        {
            sb.Append(namedDefaults ? $" CONSTRAINT {Q(c.DefaultName!)} DEFAULT {c.DefaultDef}" : $" DEFAULT {c.DefaultDef}");
        }
        return sb.ToString();
    }

    private async Task<List<string>> KeyConstraintsAsync(int objectId, CancellationToken ct, bool named = true)
    {
        var keys = await RowsAsync(
            "SELECT k.name, k.type, i.type_desc, i.index_id FROM sys.key_constraints k " +
            "JOIN sys.indexes i ON i.object_id = k.parent_object_id AND i.index_id = k.unique_index_id " +
            $"WHERE k.parent_object_id = {objectId} ORDER BY k.type, k.name", ct);
        var list = new List<string>();
        foreach (var k in keys)
        {
            var cols = await IndexColumnsAsync(objectId, (int)k[3]!, included: false, ct);
            var kind = (string)k[1]! == "PK" ? "PRIMARY KEY" : "UNIQUE";
            list.Add(named
                ? $"    CONSTRAINT {Q((string)k[0]!)} {kind} {(string)k[2]!} ({cols})"
                : $"    {kind} {(string)k[2]!} ({cols})");
        }
        return list;
    }

    private async Task<string> IndexColumnsAsync(int objectId, int indexId, bool included, CancellationToken ct)
    {
        var rows = await RowsAsync(
            "SELECT c.name, ic.is_descending_key FROM sys.index_columns ic " +
            "JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id " +
            $"WHERE ic.object_id = {objectId} AND ic.index_id = {indexId} AND ic.is_included_column = {(included ? 1 : 0)} " +
            "ORDER BY ic.key_ordinal, ic.index_column_id", ct);
        return string.Join(", ", rows.Select(r => Q((string)r[0]!) + (!included && (bool)r[1]! ? " DESC" : string.Empty)));
    }

    private async Task<List<string>> IndexesAsync(int objectId, string schema, string table, CancellationToken ct)
    {
        var idx = await RowsAsync(
            "SELECT i.name, i.index_id, i.is_unique, i.type_desc, i.filter_definition FROM sys.indexes i " +
            $"WHERE i.object_id = {objectId} AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.type IN (1, 2) AND i.is_hypothetical = 0 " +
            "ORDER BY i.name", ct);
        var list = new List<string>();
        foreach (var i in idx)
        {
            var key = await IndexColumnsAsync(objectId, (int)i[1]!, included: false, ct);
            var inc = await IndexColumnsAsync(objectId, (int)i[1]!, included: true, ct);
            var sql = $"CREATE {((bool)i[2]! ? "UNIQUE " : string.Empty)}{(string)i[3]!} INDEX {Q((string)i[0]!)} ON {Q(schema)}.{Q(table)} ({key})";
            if (inc.Length > 0) sql += $" INCLUDE ({inc})";
            if (i[4] is string filter) sql += $" WHERE {filter}";
            list.Add(sql + ";");
        }
        return list;
    }

    private async Task<List<string>> ForeignKeysAsync(int objectId, string schema, string table, CancellationToken ct)
    {
        var fks = await RowsAsync(
            "SELECT fk.object_id, fk.name, SCHEMA_NAME(rt.schema_id), rt.name, fk.delete_referential_action_desc, fk.update_referential_action_desc " +
            "FROM sys.foreign_keys fk JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id " +
            $"WHERE fk.parent_object_id = {objectId} ORDER BY fk.name", ct);
        var list = new List<string>();
        foreach (var f in fks)
        {
            var cols = await RowsAsync(
                "SELECT pc.name, rc.name FROM sys.foreign_key_columns fkc " +
                "JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id " +
                "JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id " +
                $"WHERE fkc.constraint_object_id = {(int)f[0]!} ORDER BY fkc.constraint_column_id", ct);
            var sql = $"ALTER TABLE {Q(schema)}.{Q(table)} WITH CHECK ADD CONSTRAINT {Q((string)f[1]!)} FOREIGN KEY ({string.Join(", ", cols.Select(c => Q((string)c[0]!)))}) " +
                      $"REFERENCES {Q((string)f[2]!)}.{Q((string)f[3]!)} ({string.Join(", ", cols.Select(c => Q((string)c[1]!)))})";
            if ((string)f[4]! != "NO_ACTION") sql += " ON DELETE " + ((string)f[4]!).Replace('_', ' ');
            if ((string)f[5]! != "NO_ACTION") sql += " ON UPDATE " + ((string)f[5]!).Replace('_', ' ');
            list.Add(sql + ";");
        }
        return list;
    }

    private async Task<List<string>> ChecksAsync(int objectId, string schema, string table, CancellationToken ct)
    {
        var rows = await RowsAsync($"SELECT name, definition FROM sys.check_constraints WHERE parent_object_id = {objectId} ORDER BY name", ct);
        return rows.Select(r => $"ALTER TABLE {Q(schema)}.{Q(table)} WITH CHECK ADD CONSTRAINT {Q((string)r[0]!)} CHECK {(string)r[1]!};").ToList();
    }

    // ------------------------------------------------------------------ helpers

    private static string Q(string name) => "[" + name.Replace("]", "]]") + "]";

    private static string Lit(string s) => s.Replace("'", "''");

    private async Task<List<string>> ListAsync(string sql, CancellationToken ct)
        => (await RowsAsync(sql, ct)).Select(r => (string)r[0]!).ToList();

    private async Task<List<object?[]>> RowsAsync(string sql, CancellationToken ct)
    {
        await using var cmd = new SqlCommand(sql, connection) { CommandTimeout = 300 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var list = new List<object?[]>();
        while (await r.ReadAsync(ct))
        {
            var row = new object?[r.FieldCount];
            for (var i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
            list.Add(row);
        }
        return list;
    }
}
