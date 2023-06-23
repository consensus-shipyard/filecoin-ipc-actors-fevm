module.exports = {
    semi: false,
    singleQuote: true,
    printWidth: 80,
    endOfLine: 'auto',
    tabWidth: 4,
    trailingComma: 'all',
    overrides: [
        {
            files: '*.sol',
            options: {
                parser: 'solidity-parse',
                printWidth: 120,
                tabWidth: 4,
                useTabs: false,
                singleQuote: false,
                bracketSpacing: false,
            },
        },
    ],
}