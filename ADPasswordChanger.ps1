#Requires -Version 5.1
<#
Small WPF form to change your Active Directory password by typing it,
useful in an RDP session when pasting text is disabled.
Only the currently connected account can be changed.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

# Force English culture so .NET/COM exception messages (surfaced verbatim in
# the UI) are always in English, regardless of the Windows display language.
$enUS = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
[System.Threading.Thread]::CurrentThread.CurrentCulture = $enUS
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $enUS

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Change AD Password"
        Height="370" Width="440"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen"
        Background="#F3F3F3"
        FontFamily="Segoe UI"
        FontSize="13">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <TextBlock x:Name="AccountText" Grid.Row="0" Margin="0,0,0,2" FontWeight="SemiBold" Foreground="#555555" />
        <TextBlock x:Name="ExpiryText" Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,10" FontSize="12" Foreground="#777777" />

        <TextBlock Grid.Row="2" Text="Current password" Margin="0,0,0,4" FontWeight="SemiBold" />
        <PasswordBox x:Name="OldPasswordBox" Grid.Row="3" Margin="0,0,0,10" Padding="6" BorderBrush="#CCCCCC" />

        <TextBlock Grid.Row="4" Text="New password" Margin="0,0,0,4" FontWeight="SemiBold" />
        <PasswordBox x:Name="NewPasswordBox" Grid.Row="5" Margin="0,0,0,10" Padding="6" BorderBrush="#CCCCCC" />

        <TextBlock Grid.Row="6" Text="Confirm new password" Margin="0,0,0,4" FontWeight="SemiBold" />
        <PasswordBox x:Name="ConfirmPasswordBox" Grid.Row="7" Margin="0,0,0,10" Padding="6" BorderBrush="#CCCCCC" />

        <TextBlock x:Name="StatusText" Grid.Row="8" TextWrapping="Wrap" VerticalAlignment="Top" Foreground="#C0392B" Margin="0,0,0,6" />

        <Button x:Name="ChangeButton" Grid.Row="9" Content="Change password" Padding="10,8" Background="#2D6CDF" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand" />
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$labelAccount = $window.FindName('AccountText')
$labelExpiry = $window.FindName('ExpiryText')
$boxOld = $window.FindName('OldPasswordBox')
$boxNew = $window.FindName('NewPasswordBox')
$boxConfirm = $window.FindName('ConfirmPasswordBox')
$labelStatus = $window.FindName('StatusText')
$buttonChange = $window.FindName('ChangeButton')

$labelAccount.Text = "Account: $env:USERDOMAIN\$env:USERNAME"

function Test-DomainJoinStatus {
    # Returns a hashtable: DomainJoined / AzureAdJoined are $true, $false or
    # $null (unknown, when dsregcmd could not be parsed) so callers can tell
    # "confirmed not domain-joined" apart from "detection failed".
    $result = @{ DomainJoined = $null; AzureAdJoined = $null }
    try {
        $statusText = (dsregcmd /status 2>$null | Out-String)
        if ($statusText -match 'DomainJoined\s*:\s*(YES|NO)') {
            $result.DomainJoined = ($Matches[1] -eq 'YES')
        }
        if ($statusText -match 'AzureAdJoined\s*:\s*(YES|NO)') {
            $result.AzureAdJoined = ($Matches[1] -eq 'YES')
        }
    }
    catch {
        # Leave both as $null (unknown) on failure.
    }
    return $result
}

function Get-FriendlyErrorMessage {
    param([System.Exception]$Exception)

    # PowerShell wraps method-call failures as "Exception calling "X" with "N"
    # argument(s): <real message>" and the real message is often itself a COM
    # exception several levels down - unwrap to the innermost one.
    $inner = $Exception
    while ($inner.InnerException) {
        $inner = $inner.InnerException
    }
    $message = $inner.Message

    if ($message -like '*specified network password is not correct*') {
        return 'Current password is incorrect.'
    }
    if ($message -like '*meet*length*complexity*history*' -or $message -like '*does not meet the password policy*') {
        return "The new password does not meet the domain's length, complexity or history requirements."
    }
    if ($message -like '*password was used*' -or $message -like '*password restriction*') {
        return 'The new password was used too recently (password history policy).'
    }
    if ($message -like '*account*locked*') {
        return 'This account is locked out.'
    }

    return $message
}

function Get-PasswordExpiryText {
    try {
        $currentUser = [System.DirectoryServices.AccountManagement.UserPrincipal]::Current
        $directoryEntry = $currentUser.GetUnderlyingObject()

        # msDS-UserPasswordExpiryTimeComputed is a constructed attribute: it is
        # only computed and returned by the DC when explicitly requested via
        # RefreshCache, not through a plain property/InvokeGet read.
        $directoryEntry.RefreshCache(@('msDS-UserPasswordExpiryTimeComputed'))
        $property = $directoryEntry.Properties['msDS-UserPasswordExpiryTimeComputed']
        $currentUser.Dispose()

        if ($null -eq $property -or $property.Count -eq 0) {
            return 'Password never expires.'
        }

        $rawExpiry = $property.Value
        $type = $rawExpiry.GetType()
        $high = $type.InvokeMember('HighPart', 'GetProperty', $null, $rawExpiry, $null)
        $low = $type.InvokeMember('LowPart', 'GetProperty', $null, $rawExpiry, $null)
        # LowPart/HighPart are signed Int32s; casting a negative one straight to
        # [uint32] is a *checked* conversion in PowerShell and throws instead of
        # reinterpreting the bits. Mask into an Int64 to get the unsigned bit
        # pattern without ever going through an out-of-range UInt32 cast.
        $lowUnsigned = [int64]$low -band 0xFFFFFFFFL
        $fileTime = ([int64]$high -shl 32) -bor $lowUnsigned

        if ($fileTime -eq [int64]::MaxValue -or $fileTime -eq 0) {
            return 'Password never expires.'
        }

        $expiryDate = [DateTime]::FromFileTimeUtc($fileTime)
        $daysLeft = [Math]::Ceiling(($expiryDate - [DateTime]::UtcNow).TotalDays)
        $expiryText = $expiryDate.ToString('dddd, MMMM d, yyyy - HH:mm \U\T\C')

        if ($daysLeft -lt 0) {
            return "Expired: $expiryText"
        }

        return "Expires: $expiryText  ($daysLeft day(s) left)"
    }
    catch {
        return "Password expiry unavailable ($($_.Exception.Message))"
    }
}

$joinStatus = Test-DomainJoinStatus

if ($joinStatus.DomainJoined -eq $false) {
    $labelExpiry.Foreground = [System.Windows.Media.Brushes]::DarkRed
    if ($joinStatus.AzureAdJoined -eq $true) {
        $labelExpiry.Text = 'This device is Entra ID joined only, with no on-premises Active Directory domain. This tool only supports domain-joined devices and cannot change this account''s password here.'
    } else {
        $labelExpiry.Text = 'This device is not joined to an Active Directory domain. This tool only supports domain-joined devices.'
    }

    $disabledBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE0, 0xE0, 0xE0))
    $disabledButtonBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xB0, 0xB0, 0xB0))

    foreach ($box in @($boxOld, $boxNew, $boxConfirm)) {
        $box.IsEnabled = $false
        $box.Background = $disabledBrush
    }

    $buttonChange.IsEnabled = $false
    $buttonChange.Background = $disabledButtonBrush
} else {
    $labelExpiry.Text = Get-PasswordExpiryText
}

$buttonChange.Add_Click({
    $labelStatus.Foreground = [System.Windows.Media.Brushes]::DarkRed
    $labelStatus.Text = ''

    $oldPassword = $boxOld.Password
    $newPassword = $boxNew.Password
    $confirmPassword = $boxConfirm.Password

    if ([string]::IsNullOrEmpty($oldPassword) -or [string]::IsNullOrEmpty($newPassword)) {
        $labelStatus.Text = 'All password fields are required.'
        return
    }

    if ($newPassword -ne $confirmPassword) {
        $labelStatus.Text = 'The new password and its confirmation do not match.'
        return
    }

    $buttonChange.IsEnabled = $false
    $labelStatus.Foreground = [System.Windows.Media.Brushes]::Black
    $labelStatus.Text = 'Changing password...'
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

    try {
        $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::Current
        if ($null -eq $user) {
            throw 'Could not resolve the currently connected account.'
        }

        # Safety check: UserPrincipal.Current is resolved by Windows from the
        # logged-on session token, not from any text input in this form. This
        # check re-verifies that the resolved AD object's SID matches the
        # Windows identity actually running this process, and aborts rather
        # than touching any other object if they ever diverge.
        $windowsSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $adSid = $user.Sid.Value
        if ($windowsSid -ne $adSid) {
            $user.Dispose()
            throw "Safety check failed: resolved AD account SID ($adSid) does not match the running Windows session SID ($windowsSid). Aborting, no object was modified."
        }

        $user.ChangePassword($oldPassword, $newPassword)
        $user.Dispose()

        $labelStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen
        $labelStatus.Text = 'Password changed successfully.'
        $boxOld.Password = ''
        $boxNew.Password = ''
        $boxConfirm.Password = ''
        $labelExpiry.Text = Get-PasswordExpiryText
    }
    catch {
        $labelStatus.Foreground = [System.Windows.Media.Brushes]::DarkRed
        $labelStatus.Text = Get-FriendlyErrorMessage -Exception $_.Exception
    }
    finally {
        $buttonChange.IsEnabled = $true
    }
})

$window.ShowDialog() | Out-Null
