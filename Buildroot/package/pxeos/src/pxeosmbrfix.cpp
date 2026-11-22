#include <string>
#include <iostream>
#include <fstream>

using namespace std;

int main(int argc, char* argv[])
{
    string strLine;
    int intLineCnt = 0;
    string strWriteBack = "";

    if ( argc != 3 )
    {
        cout << "Usage: " << argv[0] << " input.mbr.txt output.mbr.txt" << endl;
        cout << "Input file must be generated using the xxd application" << endl;
        return 1;
    }

    ifstream inFile(argv[1], ios::in);
    ofstream outFile( argv[2], ios::out);

    if( ! inFile )
    {
        cout << " Unable to locate mbr text file." << endl;
        return 1;
    }

    if( ! outFile )
    {
        cout << " Unable to open output file." << endl;
        return 1;
    }

    while( getline(inFile,strLine) )
    {
        intLineCnt++;
        if( ! strLine.empty() )
        {
            if ( intLineCnt == 28 || intLineCnt == 29 )
            {
                size_t colon = strLine.find(": ");
                if ( colon == string::npos )
                {
                    cout << " Invalid xxd input format." << endl;
                    return 1;
                }
                size_t hexStart = colon + 2;
                if ( intLineCnt == 28 )
                {
                    if ( strLine.size() <= hexStart + 38 )
                    {
                        cout << " Truncated xxd input line." << endl;
                        return 1;
                    }
                    for( size_t i = hexStart + 20; i < hexStart + 24; i++ )
                        strLine[i] = '0';

                    for( size_t i = hexStart + 25; i < hexStart + 29; i++ )
                        strLine[i] = '0';
                    strLine[hexStart + 37] = '2';
                    strLine[hexStart + 38] = '0';
                }
                else
                {
                    if ( strLine.size() <= hexStart + 18 )
                    {
                        cout << " Truncated xxd input line." << endl;
                        return 1;
                    }
                    strLine[hexStart] = '2';

                    for( size_t i = hexStart + 15; i < hexStart + 18; i++ )
                        strLine[i] = '0';

                    strLine[hexStart + 18] = '8';
                }
            }
            strWriteBack += strLine;
            strWriteBack += "\n";
        }
    }
    outFile << strWriteBack;
    outFile.flush();
    if ( ! outFile )
    {
        cout << " Failed to write output file." << endl;
        return 1;
    }
    return 0;
}
