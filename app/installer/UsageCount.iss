// Keep an existing choice. Both wizard setup and the one-time silent-upgrade
// prompt default to sharing when no preference has been recorded.
function UsageCountDefaultChoice(previous: string): Boolean;
begin
  previous := Trim(previous);
  if previous = '' then Result := True
  else Result := (CompareText(previous, 'true') = 0) or
    (CompareText(previous, '1') = 0) or (CompareText(previous, 'yes') = 0) or
    (CompareText(previous, 'on') = 0);
end;

// Earlier silent installers wrote false without showing the choice. A separate
// receipt is needed because that value cannot be distinguished from an opt-out.
function UsageCountNeedsChoice(receipt: string): Boolean;
begin
  Result := Trim(receipt) <> '1';
end;

function UsageCountChoiceButtons(enabled: Boolean): Integer;
begin
  Result := MB_YESNOCANCEL or MB_SETFOREGROUND;
  if not enabled then Result := Result or MB_DEFBUTTON2;
end;

function ApplyUsageCountChoice(answer: Integer; var enabled: Boolean): Boolean;
begin
  Result := (answer = IDYES) or (answer = IDNO);
  if Result then enabled := answer = IDYES;
end;

function ConfirmUsageCountChoice(var enabled: Boolean): Boolean;
var
  answer: Integer;
begin
  // MsgBox intentionally remains visible with /VERYSILENT /SUPPRESSMSGBOXES.
  // Ask before changing the installation; Cancel leaves the old app untouched.
  answer := MsgBox('Share installation count?' + #13#10 + #13#10 +
    'Every six hours while DST is open, it shares only a random installation ID, ' +
    'its edition, and app version. Your server details, players, accounts, ' +
    'settings, and logs are not shared.' + #13#10 + #13#10 +
    'The count database does not store your IP address, and count requests are ' +
    'configured to stay out of website access logs.' + #13#10 + #13#10 +
    'Sharing is optional. You can turn it off at any time in Settings.',
    mbConfirmation, UsageCountChoiceButtons(enabled));
  Result := ApplyUsageCountChoice(answer, enabled);
end;

procedure SaveUsageCountChoice(path: string; enabled: Boolean);
var
  value: string;
begin
  value := 'false';
  if enabled then value := 'true';
  // The installer and application both use the last occurrence of a key.
  // Append only this preference, preserving all prior settings and comments.
  if not SaveStringToFile(path, #13#10 + 'AnonymousUsageEnabled=' + value + #13#10 +
      'UsageCountChoiceVersion=1' + #13#10, True) then
    RaiseException('Could not save the installation count choice.');
end;
