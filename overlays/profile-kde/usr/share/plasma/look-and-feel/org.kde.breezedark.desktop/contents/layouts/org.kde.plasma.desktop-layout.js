loadTemplate("org.kde.plasma.desktop.defaultPanel")

var desktopsArray = desktopsForActivity(currentActivity());
for( var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
    desktopsArray[j].currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
    desktopsArray[j].writeConfig('Image', 'file:///usr/share/wallpapers/FlipperOne/contents/images/wallpaper.jpg');
}

// Kickoff's own defaults name kontact and discover, which this image does not install.
var panelsArray = panels();
for( var p = 0; p < panelsArray.length; p++) {
    var launchers = panelsArray[p].widgets('org.kde.plasma.kickoff');
    for( var k = 0; k < launchers.length; k++) {
        launchers[k].currentConfigGroup = ['General'];
        launchers[k].writeConfig('favorites', 'preferred://browser,org.kde.konsole.desktop,systemsettings.desktop,org.kde.dolphin.desktop,org.kde.plasma-systemmonitor.desktop');
    }
}
