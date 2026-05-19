import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;

public class Divisions implements OvertureProfile.Theme {
    final static int MAXZOOM = 12;

    @Override
    public void processFeature(SourceFeature source, FeatureCollector features) {
        String layer = source.getSourceLayer();
        String subtype = source.getString("subtype");
        int minzoom = switch (subtype) {
            case "country" -> 0;
            case "dependency" -> 0;
            case "region" -> 4;
            case "county" -> 8;
            default -> 10;
        };
        if (layer.equals("division")) {
            var point = features.point(layer);
            point.setMinZoom(minzoom);
            OvertureProfile.addFullTags(source, point, minzoom);
        } else if (layer.equals("division_boundary")) {
            var line = features.line(layer);
            line.setMinZoom(minzoom);
            line.setMinPixelSize(0);
            OvertureProfile.addFullTags(source, line, minzoom);
        } else if (layer.equals("division_area")) {
            var polygon = features.polygon(layer);
            polygon.setMinZoom(minzoom);
            polygon.setMinPixelSize(0);
            OvertureProfile.addFullTags(source, polygon, minzoom);
        }
    }

    @Override
    public String name() {
        return "divisions";
    }

    public static void main(String[] args) throws Exception {
        OvertureProfile.run(Arguments.fromArgsOrConfigFile(args).orElse(Arguments.of("maxzoom", MAXZOOM)), new Divisions());
    }
}