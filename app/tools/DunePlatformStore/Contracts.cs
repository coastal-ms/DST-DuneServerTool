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

internal sealed record ReplaceInventoryRequest
{
    public string Generation { get; init; } = "";
    public DateTimeOffset ObservedAt { get; init; }
    public DateTimeOffset CachedAt { get; init; }
    public DateTimeOffset ExpiresAt { get; init; }
    public string SourceFingerprint { get; init; } = "";
    public IReadOnlyList<InventoryItemInput> Items { get; init; } = [];
}

internal sealed record InventoryItemInput
{
    public long ItemId { get; init; }
    public string TemplateId { get; init; } = "";
    public string DisplayName { get; init; } = "";
    public string Kind { get; init; } = "";
    public long Quantity { get; init; }
    public int Quality { get; init; }
    public string Durability { get; init; } = "";
    public string MaxDurability { get; init; } = "";
    public string WaterAmount { get; init; } = "";
    public string WaterType { get; init; } = "";
    public InventoryMetadataInput Metadata { get; init; } = new();
    public long InventoryId { get; init; }
    public int InventoryType { get; init; }
    public string EntityType { get; init; } = "";
    public long EntityId { get; init; }
    public string EntityLabel { get; init; } = "";
    public string Owner { get; init; } = "";
    public string Map { get; init; } = "";
    public string EntityClass { get; init; } = "";
    public long? PlayerId { get; init; }
    public string? PlayerName { get; init; }
}

internal sealed record InventoryMetadataInput
{
    public string Category { get; init; } = "";
    public int? Tier { get; init; }
    public string Rarity { get; init; } = "";
    public string Icon { get; init; } = "";
    public int StackMaximum { get; init; }
    public double? Volume { get; init; }
    public long VendorPrice { get; init; }
    public bool IsGradeable { get; init; }
}

internal abstract record InventoryFilterRequest
{
    public IReadOnlyList<string> EntityTypes { get; init; } = ["player", "storage"];
    public string? ScopeType { get; init; }
    public long? ScopeId { get; init; }
    public long? PlayerId { get; init; }
    public string? LocationType { get; init; }
    public long? LocationId { get; init; }
    public int Offset { get; init; }
}

internal sealed record QueryInventoryRequest : InventoryFilterRequest
{
    public string Query { get; init; } = "";
    public string Sort { get; init; } = "name-asc";
    public int Limit { get; init; } = 100;
}

internal sealed record QueryInventoryOccurrencesRequest : InventoryFilterRequest
{
    public string TemplateId { get; init; } = "";
    public string Sort { get; init; } = "player-asc";
    public int Limit { get; init; } = 50;
}

internal sealed record InventoryRefreshTriggerRequest
{
    public string Trigger { get; init; } = "";
}
