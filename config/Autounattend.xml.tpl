<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <!-- === windowsPE pass: disk partitioning + image selection === -->
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <!-- Load VirtIO storage driver so Windows PE can see the virtio disk -->
    <component name="Microsoft-Windows-PnPCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DriverPaths>
        <!-- Try multiple drive letters — CD-ROM assignment varies -->
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>D:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>D:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>E:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4">
          <Path>E:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5">
          <Path>F:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6">
          <Path>F:\viostor\w11\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7">
          <Path>G:\viostor\2k22\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8">
          <Path>G:\viostor\w11\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

      {{WIN_PRODUCT_KEY_BLOCK}}

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <!-- System Reserved (boot) -->
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>350</Size>
              <Type>Primary</Type>
            </CreatePartition>
            <!-- Windows OS -->
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>NTFS</Format>
              <Label>System Reserved</Label>
              <Active>true</Active>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>1</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>2</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>

  <!-- === specialize pass: hostname, timezone, firewall === -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>{{WIN_HOSTNAME}}</ComputerName>
      <TimeZone>{{WIN_TIMEZONE}}</TimeZone>
    </component>

    <!-- Disable Windows Recovery Environment + unnecessary services for faster install -->
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <!-- Disable Windows Recovery Environment -->
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd /c reagentc /disable</Path>
        </RunSynchronousCommand>
        <!-- Disable Windows Search indexing -->
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>cmd /c sc config WSearch start= disabled</Path>
        </RunSynchronousCommand>
        <!-- Disable SysMain (Superfetch) -->
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd /c sc config SysMain start= disabled</Path>
        </RunSynchronousCommand>
        <!-- Disable Windows Update during install -->
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>cmd /c sc config wuauserv start= disabled</Path>
        </RunSynchronousCommand>
        <!-- Disable Defender real-time monitoring -->
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>powershell -NoProfile -Command "Set-MpPreference -DisableRealtimeMonitoring $true" </Path>
        </RunSynchronousCommand>
        <!-- Copy setup.ps1 from answer ISO to C:\ while CD is still mounted -->
        <RunSynchronousCommand wcm:action="add">
          <Order>6</Order>
          <Path>powershell -NoProfile -Command "foreach ($d in 68..90) { $p = [char]$d + ':\setup.ps1'; if (Test-Path $p) { Copy-Item $p C:\setup.ps1 -Force; break } }"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>

    <!-- Disable Windows Firewall for SSH access -->
    <component name="Networking-MPSSVC-Svc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
      <PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
      <PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
    </component>
  </settings>

  <!-- === oobeSystem pass: admin password, skip OOBE === -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

      <UserAccounts>
        <AdministratorPassword>
          <Value>{{WIN_ADMIN_PASSWORD}}</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>{{WIN_ADMIN_PASSWORD}}</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>3</LogonCount>
      </AutoLogon>

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <FirstLogonCommands>
        <!-- Run post-install setup script from answer ISO -->
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File C:\setup.ps1</CommandLine>
          <Description>Post-install setup</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>

</unattend>
