function Download-File 
{
  param (
    [string]$url,
    [string]$saveAs
  )
 
  Write-Host "  Downloading $url to $saveAs"
  $downloader = new-object System.Net.WebClient
  $downloader.DownloadFile($url, $saveAs)
}

# Installing ASP.NET Core Runtime - Windows Hosting Bundle Installer so that we can deploy ,.NET Core websites
$dotnetversion = "2.1.22"
$dotnetUrl = "https://download.visualstudio.microsoft.com/download/pr/2fe0ef0c-a6b6-4cda-b6b8-874068bb131f/709d1c7817fa19524089dda74933ddce/dotnet-hosting-2.1.22-win.exe"
$dotnetHostingBundleInstaller = "$startupDir/dotnet-hosting-$dotnetversion-win.exe"

Write-Output "Downloading ASP.NET Core Runtime - Windows Hosting Bundle Installer v$dotnetversion"

if ((test-path $dotnetHostingBundleInstaller) -ne $true) {
    try {
      Download-File -url $dotnetUrl -SaveAs $dotnetHostingBundleInstaller 
    }
    catch {
      # Apparently this download can sometimes be a bit flakey. Sometimes hitting a 404.
      Write-Warning "First attempt to download dotnet core failed with error: $Error[0]"
      Write-output "Trying 10 more times..."
      for ($i = 1; $i -lt 11; $i++){
        Start-Sleep 1
        Write-output "Attempte $i / 10"
        try {
          Download-File -url $dotnetUrl -SaveAs $dotnetHostingBundleInstaller 
          Write-Output "worked this time"
          break
        }
        catch {
          Write-Output "failed"
        }  
      }
    }    
}
else {
    Write-Output "  dotnet core hosting bundle already downloaded to $dotnetHostingBundleInstaller"
}

Write-Output "  Installing ASP.NET Core Runtime (v$dotnetversion) - Windows Hosting Bundle Installer."
$args = New-Object -TypeName System.Collections.Generic.List[System.String]
$args.Add("/quiet")
$args.Add("/install")
$args.Add("/norestart")
$Output = Start-Process -FilePath $dotnetHostingBundleInstaller -ArgumentList $args -NoNewWindow -Wait -PassThru

Write-Output "  Re-starting IIS."
If($Output.Exitcode -Eq 0)
{
    net stop was /y
    net start w3svc
}
else {
    Write-Error "`t`t Something went wrong with the installation. Errorlevel: ${Output.ExitCode}"
    Exit 1
}
