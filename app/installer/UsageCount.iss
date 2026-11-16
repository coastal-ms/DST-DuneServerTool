// Keep an existing choice. Silent setup cannot present a first-time choice.
function UsageCountDefaultChoice(previous: string; silent: Boolean): Boolean;
begin
  previous := Trim(previous);
  if previous = '' then Result := not silent
  else Result := (CompareText(previous, 'true') = 0) or
    (CompareText(previous, '1') = 0) or (CompareText(previous, 'yes') = 0) or
    (CompareText(previous, 'on') = 0);
end;

procedure SaveUsageCountChoice(path: string; enabled: Boolean);
var
  value: string;
begin
  value := 'false';
  if enabled then value := 'true';
  // The installer and application both use the last occurrence of a key.
  // Append only this preference, preserving all prior settings and comments.
  if not SaveStringToFile(path, #13#10 + 'AnonymousUsageEnabled=' + value + #13#10, True) then
    RaiseException('Could not save the installation count choice.');
end;
