import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;

public class Base implements OvertureProfile.Theme {
    final static int MAXZOOM = 13;

    @Override
    public void processFeature(SourceFeature source, FeatureCollector features) {
        String layer = source.getSourceLayer();
        String subtype = source.getString("subtype");
        var feature = OvertureProfile.createAnyFeature(source, features);
        if (layer.equals("infrastructure")) {
            feature.setMinZoom(13);
            OvertureProfile.addFullTags(source, feature, MAXZOOM);
        } else if (layer.equals("land")) {
            int minzoom = 7;
            if (source.isPoint()) {
                minzoom = 13;
            } else if (subtype.equals("land") || subtype.equals("glacier")) {
                minzoom = 0;
            }
            if (minzoom == 0) {
                feature.setMinPixelSize(0);
            }
            feature.setMinZoom(minzoom);
            OvertureProfile.addFullTags(source, feature, MAXZOOM);
        }  else if (layer.equals("bathymetry")) {
            feature.setMinPixelSize(0);
            feature.setMinZoom(0);
            OvertureProfile.addFullTags(source, feature, MAXZOOM);
        } else if (layer.equals("land_use")) {
            int minzoom = 9;
            if (source.isPoint()) {
                minzoom = 13;
            } else if (subtype.equals("residential")) {
                minzoom = 6;
            }
            feature.setMinZoom(minzoom);
            OvertureProfile.addFullTags(source, feature, MAXZOOM);
        } else if (layer.equals("land_cover")) {
            var cartography = source.getStruct("cartography");
            var minZoom = cartography.get("min_zoom").asInt();
            feature.setMaxZoom(cartography.get("max_zoom").asInt());
            feature.setMinZoom(minZoom);
            OvertureProfile.addFullTags(source, feature, minZoom);
        } else if (layer.equals("water")) {
            int minZoom = 13;
            if (source.isPoint()) {
                if (subtype.equals("ocean")) {
                    minZoom = 0;
                } else {
                    minZoom = 8;
                }
            } else {
                if (subtype.equals("ocean")) {
                    minZoom = 0;
                    feature.setMinPixelSize(0);
                } else if (source.canBePolygon()) {
                    minZoom = 4;
                    feature.setMinPixelSize(0);
                } else if (subtype.equals("river")) {
                    minZoom = 9;
                }
            }
            feature.setMinZoom(minZoom);
            OvertureProfile.addFullTags(source, feature, minZoom);
        }
    }


    @Override
    public String name() {
        return "base";
    }

    public static void main(String[] args) throws Exception {
        OvertureProfile.run(Arguments.fromArgsOrConfigFile(args).orElse(Arguments.of("maxzoom", MAXZOOM)), new Base());
    }
}

