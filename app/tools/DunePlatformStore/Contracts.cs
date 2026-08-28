namespace DunePlatformStore;

internal sealed record ReplaceGenerationRequest
{
    public string Generation { get; init; } = "";
    public IReadOnlyList<SourceStateInput> Sources { get; init; } = [];
    public IReadOnlyList<MapCatalogInput> Maps { get; init; } = [];
    public IReadOnlyList<LayerSnapshotInput> Layers { get; init; } = [];
    public IReadOnlyList<ActiveSpiceInput> ActiveSpiceCurrent { get; init; } = [];
    public IReadOnlyList<ActiveSpiceInput> ActiveSpiceHistory { get; init; } = [];
    public IReadOnlyList<PublicPoiInput> PublicPois { get; init; } = [];
}

internal sealed record SourceStateInput
{
    public string SourceKey { get; init; } = "";
    public string SchemaFingerprint { get; init; } = "";
    public DateTimeOffset? LastAttemptAt { get; init; }
    public DateTimeOffset? LastSuccessAt { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
    public string? LastErrorCode { get; init; }
}

internal sealed record MapCatalogInput
{
    public string FarmId { get; init; } = "";
    public string MapId { get; init; } = "";
    public string PartitionId { get; init; } = "";
    public string Label { get; init; } = "";
    public string Kind { get; init; } = "";
    public DateTimeOffset LastSeenAt { get; init; }
    public bool Active { get; init; }
}

internal sealed record LayerSnapshotInput
{
    public string FarmId { get; init; } = "";
    public string MapId { get; init; } = "";
    public string PartitionId { get; init; } = "";
    public string LayerId { get; init; } = "";
    public string SourceKey { get; init; } = "";
    public DateTimeOffset? ObservedAt { get; init; }
    public DateTimeOffset CachedAt { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
    public string FreshnessState { get; init; } = "";
    public string? LastErrorCode { get; init; }
    public int RowCount { get; init; }
    public bool Truncated { get; init; }
    public string PayloadSha256 { get; init; } = "";
}

internal sealed record ActiveSpiceInput
{
    public string FarmId { get; init; } = "";
    public string MapId { get; init; } = "";
    public string PartitionId { get; init; } = "";
    public string FieldId { get; init; } = "";
    public string State { get; init; } = "";
    public string CoordinateSpace { get; init; } = "";
    public double? X { get; init; }
    public double? Y { get; init; }
    public string SourceFingerprint { get; init; } = "";
    public DateTimeOffset ObservedAt { get; init; }
    public DateTimeOffset ExpiresAt { get; init; }
}

internal sealed record PublicPoiInput
{
    public string FarmId { get; init; } = "";
    public string MapId { get; init; } = "";
    public string PartitionId { get; init; } = "";
    public string Id { get; init; } = "";
    public string Category { get; init; } = "";
    public string Label { get; init; } = "";
    public string CoordinateSpace { get; init; } = "";
    public double X { get; init; }
    public double Y { get; init; }
    public string SourceFingerprint { get; init; } = "";
    public DateTimeOffset ObservedAt { get; init; }
    public DateTimeOffset ExpiresAt { get; init; }
}

internal sealed record MapSnapshot(
    string Generation,
    DateTimeOffset HydratedAt,
    IReadOnlyList<object> Sources,
    IReadOnlyList<MapCatalogInput> Maps,
    IReadOnlyList<LayerSnapshotInput> Layers,
    IReadOnlyList<ActiveSpiceInput> ActiveSpice,
    IReadOnlyList<ActiveSpiceInput> ActiveSpiceHistory,
    IReadOnlyList<PublicPoiInput> PublicPois);
