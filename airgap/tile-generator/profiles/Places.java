import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;
import com.onthegomap.planetiler.reader.parquet.ParquetFeature;
import org.apache.parquet.schema.MessageType;

public class Places implements OvertureProfile.Theme {

    @Override
    public void processFeature(SourceFeature source, FeatureCollector features) {
        String layer = source.getSourceLayer();
        var point = features.point(layer).setMinZoom(14);
        OvertureProfile.addFullTags(source, point, 14);
    }

    @Override
    public String name() {
        return "places";
    }

    public static void main(String[] args) throws Exception {
        OvertureProfile.run(Arguments.fromArgsOrConfigFile(args), new Places());
    }
}