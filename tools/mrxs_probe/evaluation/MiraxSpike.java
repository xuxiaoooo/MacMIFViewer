import com.glencoesoftware.bioformats2raw.MiraxReader;
import java.util.Arrays;
import loci.formats.FormatTools;

public class MiraxSpike {
    public static void main(String[] args) throws Exception {
        try (MiraxReader reader = new MiraxReader()) {
            reader.setId(args[0]);
            int w = reader.getSizeX(), h = reader.getSizeY();
            System.out.printf("series=%d dimensions=%dx%d channels=%d dtype=%s%n",
                reader.getSeriesCount(), w, h, reader.getSizeC(),
                FormatTools.getPixelTypeString(reader.getPixelType()));
            for (int c = 0; c < reader.getSizeC(); c++) {
                byte[] roi = reader.openBytes(reader.getIndex(0, c, 0), w / 2, h / 2, 128, 128);
                long nonzero = 0;
                for (byte b : roi) if (b != 0) nonzero++;
                System.out.printf("channel=%d bytes=%d nonzero_bytes=%d array_hash=%d%n",
                    c, roi.length, nonzero, Arrays.hashCode(roi));
            }
        }
    }
}
